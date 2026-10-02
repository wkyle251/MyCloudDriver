# RAR password fixtures

Small archives encoded as base64 so the header tests do not require RAR or
UnRAR to be installed. They contain only synthetic test text. They are used by
`src/similarity_password_rar.rs` and `scripts/test-similarity-password-skip.py`.

The RAR4 fixtures come from libarchive's public test suite (retrieved 2026-09-12):

- `rar4-data.rar.b64`: [`test_read_format_rar_encryption_data.rar.uu`](https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar_encryption_data.rar.uu)
- `rar4-header.rar.b64`: [`test_read_format_rar_encryption_header.rar.uu`](https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar_encryption_header.rar.uu)

They were decoded from uuencode and re-encoded as base64 without changing the
archive bytes. The upstream notice is reproduced in `LICENSE.libarchive`.

The RAR5 fixtures were generated with RAR 7.23 for macOS ARM using the password
`fixture-password`. The generator is not included and is not needed to run tests.

```sh
printf 'Public synthetic test entry.\n' > public.txt
printf 'Synthetic password-protected test content.\n' > protected.txt
rar a -idq -m0 -pfixture-password rar5-data.rar protected.txt
rar a -idq -m0 -hpfixture-password rar5-header.rar protected.txt
rar a -idq -m0 rar5-plain.rar public.txt
rar a -idq -m0 rar5-mixed.rar public.txt
rar a -idq -m0 -pfixture-password rar5-mixed.rar protected.txt
```

`data` encrypts file contents; `header` also encrypts filenames; `mixed` has a
public first entry followed by a protected entry. `plain` is unencrypted. Salt,
IV and timestamps make regenerated archive bytes differ. The integration test
also constructs sparse RAR4 and RAR5 files with a 5 GiB public member to verify
that the probe seeks to later headers without downloading the intervening data.
