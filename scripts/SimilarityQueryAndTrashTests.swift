import AppKit
import Foundation

@main @MainActor struct SimilarityQueryAndTrashTests {
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(90)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Generated saved-query fixture timed out")
    }
    static func python(_ script: String, arguments: [String]) throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c",script] + arguments
        try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 0)
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default, resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("saved-query-tests-\(UUID())", isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let data = root.appendingPathComponent("data"), sources = root.appendingPathComponent("sources")
        try fm.createDirectory(at:sources,withIntermediateDirectories:true)
        let run = "mcd2-" + UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let files: [SimilarityFile] = (0..<4096).map { i in
            let path = sources.appendingPathComponent("generated-\(i).txt").path
            return SimilarityFile(id:"generated-\(i)-" + String(repeating:"x",count:9000),name:"generated-\(i).txt",
                path:path,bytes:100,family:"text",localPath:path,cloudId:nil,ancestors:[],engineIndex:UInt64(i),state:"ready")
        }
        let metadata = root.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject:["run":run,"ids":files.map(\.id)]).write(to:metadata)
        try python("""
import pathlib,sys,json,sqlite3
root=pathlib.Path(sys.argv[1]);meta=json.loads(pathlib.Path(sys.argv[2]).read_text());ids=meta['ids']
(root/'runs').mkdir(parents=True)
with sqlite3.connect(root/'runs'/(meta['run']+'.sqlite3')) as db:
 db.executescript('CREATE TABLE run(id TEXT,revision INTEGER,summary TEXT); CREATE TABLE files(ordinal INTEGER PRIMARY KEY,id TEXT UNIQUE,digest TEXT,family TEXT,profile TEXT,available INTEGER,payload TEXT,extraction TEXT,diagnostic TEXT); CREATE TABLE scores(a INTEGER,b INTEGER,score REAL,PRIMARY KEY(a,b)) WITHOUT ROWID; CREATE INDEX scores_b ON scores(b);')
 db.execute('INSERT INTO run VALUES(?,1,?)',(meta['run'],'{}'))
 db.executemany('INSERT INTO files VALUES(?,?,NULL,?,?,1,?,NULL,NULL)',((i,id,'text','fixture','{}') for i,id in enumerate(ids)))
 db.executemany('INSERT INTO scores VALUES(0,?,.96)',((i,) for i in range(1,len(ids))))
with sqlite3.connect(root/'filetwin-sources.sqlite3') as db:
 db.executescript('CREATE TABLE vectors(digest TEXT,profile TEXT,payload BLOB,seen_at INTEGER,PRIMARY KEY(digest,profile)) WITHOUT ROWID; CREATE TABLE sources(identity TEXT,revision TEXT,profile TEXT,digest TEXT,seen_at INTEGER,PRIMARY KEY(identity,revision,profile)) WITHOUT ROWID; CREATE INDEX sources_digest ON sources(digest,profile); CREATE TABLE outcomes(identity TEXT,revision TEXT,reader TEXT,payload BLOB,seen_at INTEGER,PRIMARY KEY(identity,revision,reader)) WITHOUT ROWID;')
 db.execute("INSERT INTO vectors VALUES('shared','fixture',x'01',1)")
 db.executemany("INSERT INTO sources VALUES(?,'revision','fixture','shared',1)",(('provider:'+ids[i],) for i in (1,2)))
""", arguments:[data.path,metadata.path])
        let config = SimilarityConfiguration(executable:resources.appendingPathComponent("pikpak"),models:resources.appendingPathComponent("FileTwinModels"),
            worker:resources.appendingPathComponent("filetwin-worker"),dataDirectory:data,temporaryDirectory:root.appendingPathComponent("queries"),environment:[:])
        var request: [String:Any] = ["data_dir":data.path,"run_id":run,"result_revision":1,"file_id":files[0].id,"row_offset":0]
        do {
            let output = try await SimilarityHelper.request(configuration:config,command:"similarity-scores",input:JSONSerialization.data(withJSONObject:request))
            precondition(output.count > 32 << 20, "Fixture must cross the former response limit")
        }
        request["compact"] = true
        let compact = try await SimilarityHelper.request(configuration:config,command:"similarity-scores",input:JSONSerialization.data(withJSONObject:request))
        let decoder=JSONDecoder();decoder.keyDecodingStrategy = .convertFromSnakeCase
        let row=try decoder.decode(SimilarityScoreRow.self,from:compact)
        precondition(compact.count < 1 << 20 && row.entries.count==4095 && row.entries.allSatisfy { $0.fileId == nil && $0.ordinal != nil })
        print("PASS a real saved row above 32 MiB loads; compact ordinal transport retains every score below 1 MiB")
        let report = SimilarityReport(source:.local,scope:[sources.path],status:"completed",threshold:0.94,scannedFiles:4096,
            analysedFiles:4096,skippedFiles:0,downloadedBytes:0,totalGroups:0,groups:[],issues:[],truncated:false,
            coverage:"Generated",elapsedSeconds:1,files:files,runId:run,resultRevision:1,scoresRetained:4095)
        let model=SimilarityResultsModel();model.load(report,configuration:config)
        try await wait { !model.isIndexing && !model.isGrouping }
        model.showAllFiles();model.select(files[0].id)
        try await wait { !model.isLoading && (model.error != nil || model.related.count == 4095) }
        precondition(model.error==nil && model.related.count==4095 && model.omitted==0)
        let store=DiskTrash(volumeRoot:sources,volumeID:LocalFileAccess.volumeID(sources))
        let original=URL(fileURLWithPath:files[1].localPath!);try Data(repeating:65,count:100).write(to:original)
        var undo:CloudDriveUndo?
        model.moveToTrash(files[1]) { _ in undo=try await store.trash([original],title:"Generated saved-query Trash",progress:{ _ in }) }
        try await wait { model.trashingIDs.isEmpty };await model.waitForSavedMutations()
        precondition(model.trashedIDs.contains(files[1].id) && !fm.fileExists(atPath:original.path))
        try python("""
import sqlite3,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);id=json.loads(pathlib.Path(sys.argv[2]).read_text())['ids'][1]
with sqlite3.connect(root/'filetwin-sources.sqlite3') as db:
 assert db.execute('SELECT count(*) FROM sources WHERE identity=?',('provider:'+id,)).fetchone()[0]==0
 assert db.execute('SELECT count(*) FROM vectors').fetchone()[0]==1
 assert db.execute('SELECT count(*) FROM retired_sources').fetchone()[0]==1
""", arguments:[data.path,metadata.path])
        let reopened=SimilarityResultsModel();reopened.load(report,configuration:config)
        try await wait { !reopened.isIndexing };await reopened.waitForSavedMutations()
        precondition(reopened.trashedIDs.contains(files[1].id) && reopened.visibleFileCount==4095)
        reopened.showAllFiles();reopened.select(files[0].id)
        try await wait { !reopened.isLoading && (reopened.error != nil || reopened.related.count == 4094) }
        precondition(!reopened.related.contains { $0.id == files[1].id } && reopened.related.count==4094)
        let savedUndo = reopened.savedTrashUpdater([files[1].id])!
        reopened.reset()
        _ = try await undo!.apply();try await savedUndo(false)
        let excludedAfterUndo = try SimilarityResultExclusions.load(report,configuration:config)
        precondition(excludedAfterUndo.isEmpty)
        precondition(fm.fileExists(atPath:original.path))
        print("PASS confirmed Trash removes saved rows and vector associations across reopening; a retained duplicate keeps its vector and Undo restores the comparison after its window closes")
        try await DiskTrashTests.main()
        try await SimilarityTests.main()
        try await SimilarityTreeExpansionTests.main()
    }
}
