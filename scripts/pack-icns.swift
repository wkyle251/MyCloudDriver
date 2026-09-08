#!/usr/bin/env swift

import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: pack-icns.swift ICONSET_DIRECTORY OUTPUT.icns\n", stderr)
    exit(2)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])

let representations: [(type: String, filename: String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png"),
]

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { bytes in
            append(contentsOf: bytes)
        }
    }
}

var body = Data()
do {
    for representation in representations {
        let type = Data(representation.type.utf8)
        guard type.count == 4 else {
            fputs("invalid ICNS type: \(representation.type)\n", stderr)
            exit(1)
        }
        let png = try Data(contentsOf: iconset.appendingPathComponent(representation.filename))
        let chunkLength = png.count + 8
        guard chunkLength <= Int(UInt32.max) else {
            fputs("icon representation is too large\n", stderr)
            exit(1)
        }
        body.append(type)
        body.appendBigEndian(UInt32(chunkLength))
        body.append(png)
    }

    let totalLength = body.count + 8
    guard totalLength <= Int(UInt32.max) else {
        fputs("ICNS file is too large\n", stderr)
        exit(1)
    }

    var result = Data("icns".utf8)
    result.appendBigEndian(UInt32(totalLength))
    result.append(body)
    try result.write(to: output, options: .atomic)
} catch {
    fputs("could not build ICNS: \(error.localizedDescription)\n", stderr)
    exit(1)
}
