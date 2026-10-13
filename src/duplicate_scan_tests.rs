use super::*;
use crate::guest_fixture::Fixture;
use pikpak::duplicate_cache::DuplicateCache;
use std::sync::atomic::Ordering;

fn client(fixture: &Fixture, directory: &StdPath) -> Client {
    Client::builder()
        .refresh_token("fixture-refresh")
        .device_id("fixture-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_duplicate_cache_directory(directory.to_owned())
}

#[tokio::test]
async fn repeated_duplicate_scans_ignore_stale_inventory_and_fetch_current_metadata() {
    let fixture = Fixture::new().await;
    let directory = tempfile::tempdir().unwrap();
    let client = client(&fixture, directory.path());
    client.list_folder("").await.unwrap();
    client.list_folder("saved-folder").await.unwrap();
    let cache = DuplicateCache::open(directory.path(), "account-user").unwrap();
    let mut phantom = cache.folder("saved-folder").unwrap().unwrap()[0].clone();
    phantom.id = "cached-phantom".into();
    phantom.name = "Only in old inventory.bin".into();
    cache.upsert_files("saved-folder", &[phantom]).unwrap();
    let count_listings = || {
        fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request.starts_with("GET /drive/v1/files?"))
            .count()
    };
    let before = count_listings();

    for run in 1..=2 {
        let scan = scan_duplicates(&client, "", "/", false).await.unwrap();
        assert_eq!(
            (scan.scanned_folders, scan.scanned_files, scan.exact_groups),
            (2, 1, 0)
        );
        assert_eq!(
            count_listings(),
            before + run * 2,
            "every scan must fetch every folder"
        );
        assert_eq!(
            cache.folder("saved-folder").unwrap().unwrap().len(),
            2,
            "scanning must not write the inventory used by other operations"
        );
    }

    fixture.gone.store(true, Ordering::SeqCst);
    let removed = scan_duplicates(&client, "", "/", false).await.unwrap();
    assert_eq!(
        removed.scanned_files, 0,
        "external changes are visible without a refresh option"
    );
    assert_eq!(count_listings(), before + 6);
}

#[tokio::test]
async fn cloud_duplicate_checks_do_not_create_an_inventory_cache() {
    let fixture = Fixture::new().await;
    let directory = tempfile::tempdir().unwrap();
    let unused = directory.path().join("Unused Cache");
    let client = client(&fixture, &unused);
    for _ in 0..2 {
        let scan = scan_duplicates(&client, "", "/", false).await.unwrap();
        assert_eq!((scan.scanned_folders, scan.scanned_files), (2, 1));
        assert!(
            !unused.exists(),
            "duplicate checking must neither read nor create cache storage"
        );
    }
    let selected = scan_duplicates(&client, "saved-folder", "/Saved", false)
        .await
        .unwrap();
    assert_eq!(selected.scanned_files, 1);
    assert!(
        !unused.exists(),
        "selected-folder metadata must also bypass the cache"
    );
}

#[test]
fn duplicate_cli_keeps_duplicate_checking_and_removes_the_cache_switch() {
    assert!(matches!(
        Cli::try_parse_from(["pikpak", "duplicates"])
            .unwrap()
            .command,
        Command::Duplicates(_)
    ));
    assert!(Cli::try_parse_from(["pikpak", "duplicates", "--refresh-cache"]).is_err());
}
