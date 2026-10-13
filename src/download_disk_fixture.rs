//! Newly created disk images for tests: a disk is mounted for one test and
//! detached afterwards. Never a user's disk.
use std::path::{Path, PathBuf};

pub struct TestDisk {
    pub mount: PathBuf,
}

impl TestDisk {
    pub fn new(root: &Path, name: &str, filesystem: &str, megabytes: u32) -> Self {
        let image = root.join(format!("{name}.dmg"));
        let mount = root.join(name);
        let hdiutil = |arguments: &[&str]| {
            let output = std::process::Command::new("/usr/bin/hdiutil")
                .args(arguments)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "hdiutil {arguments:?}: {}",
                String::from_utf8_lossy(&output.stdout)
            );
        };
        hdiutil(&[
            "create",
            "-size",
            &format!("{megabytes}m"),
            "-fs",
            filesystem,
            "-volname",
            name,
            image.to_str().unwrap(),
        ]);
        hdiutil(&[
            "attach",
            image.to_str().unwrap(),
            "-nobrowse",
            "-mountpoint",
            mount.to_str().unwrap(),
        ]);
        Self { mount }
    }
}

impl Drop for TestDisk {
    fn drop(&mut self) {
        let _ = std::process::Command::new("/usr/bin/hdiutil")
            .args(["detach", self.mount.to_str().unwrap(), "-force"])
            .output();
    }
}

/// Every file in `from` whose name starts with `prefix`, copied the way a backup and restore
/// does: a new device, inode and modification time, and no hole-preserving tricks.
pub fn copy_files(from: &Path, to: &Path, prefix: &str) -> Vec<String> {
    std::fs::create_dir_all(to).unwrap();
    let mut names = Vec::new();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with(prefix) && entry.file_type().unwrap().is_file() {
            std::fs::copy(entry.path(), to.join(&name)).unwrap();
            names.push(name);
        }
    }
    names.sort();
    names
}
