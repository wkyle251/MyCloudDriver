# PikPak Personal Access Tokens

MyCloudDriver supports the official Personal Access Token (PAT) available in
PikPak → Account & Security → Connected Apps. In MyCloudDriver, open the
PikPak account card in the left sidebar and choose Token login → Connect.
The same controls are available in Settings → Accounts → Login method. Paste the token into the secure field and
choose **Verify & Connect**. A removed/revoked token cannot be reused.

The new token is staged in a private directory, then checked against PikPak's
account service and a one-item file listing. It must belong to the selected
account and allow reading files. A failed or cancelled check leaves the old
connection intact. A successful check saves the token alongside normal login;
only a previous token for the same user is replaced.
Account transfer history continues to use the verified PikPak account ID.

## Authentication and permissions

- PATs are direct bearer credentials, separate from desktop OAuth refresh tokens.
- PATs never go through refresh-token or first-party captcha exchanges.
- Identity comes from the authenticated `/v1/user/me` response, not from trusting
  unverified local JWT claims.
- Read files supports browsing, downloading, previews and similarity scans.
  File mutations require the corresponding permissions chosen in PikPak.
- Expiry and revocation require a replacement token. There is no silent fallback
  to the old OAuth session. PikPak Sign-in remains available as a connection method.
- Tokens are stored in account-specific files with mode 0600 inside directories
  with mode 0700. Account indexes contain connection type and display metadata.
  Helpers receive the token file path, never the token in arguments or environment.

## Download modes

The selected account credential and the content mode are independent:

| Mode | Content access |
| --- | --- |
| User | Uses the selected account connection, including PAT authentication. |
| Guest | Uses public-share access. Account metadata uses the selected connection. |
| Dynamic | Tries guest access, then uses the selected account connection if needed. |

This applies to Browser/Links, downloads, previews, and similarity downloads to
RAM. The account token is never attached to guest verification or signed content
URLs. Replacing credentials requires idle account work in the current workspace.

## Transfer allowance

PikPak Connected Apps share **25% of the account's valid monthly quota** in each
transfer dimension. Their usage also counts toward the full account quota;
this is not additional allowance. A PAT does not convert downstream transfers
into cloud-download traffic. The live sidebar shows Connected Apps usage and
limits when Token login is selected. Quota details compare these with the
full account counters shown for Normal login. Missing app counters are never
replaced with account counters or estimated limits.

## Evidence and limits

Checked 16 September 2026:

- [Official PAT documentation](https://mypikpak.com/en-US/help-center/connected_apps/personal_access_tokens)
- [Official FAQ: permissions, expiry and Connected Apps limits](https://mypikpak.com/en-US/faq)
- [Official CLI](https://mypikpak.com/en-US/cli), version 0.5.0: `auth token --help`
  documents PAT authentication and `PIKPAK_TOKEN` precedence. Read-only requests
  with a synthetic invalid token confirmed bearer credentials go to `/v1/user/me`
  and `/drive/v1/files` without an OAuth refresh or captcha exchange. This
  establishes the request protocol, not successful live authorization.

The MyCloudDriver CLI accepts `PIKPAK_PERSONAL_ACCESS_TOKEN_FILE`, pointing to a
private regular file. An explicitly configured missing, empty, symlinked or
non-private PAT file fails without trying an inherited OAuth token.
