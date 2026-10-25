# 05 · Deployment

Everything except the database and the data sources runs on the user's Mac. The services listen on the loopback
interface only.

```mermaid
C4Deployment
    title Deployment — MxDataHUB

    Deployment_Node(mac, "User's Mac", "macOS 26.6+, Apple silicon") {
        Deployment_Node(apps, "/Applications", "Signed app bundles") {
            Container(hub, "MxDataHUB.app", "SwiftUI, App Sandbox: outgoing network")
            Container(wms, "MxJobsMGR.app", "SwiftUI, App Sandbox")
        }
        Deployment_Node(loopback, "Loopback 127.0.0.1", "started by Services/mxservices.py or launchd agents") {
            Container(loader, "srm-loader :8770", "Python")
            Container(analytics, "analytics :8772", "Python")
            Container(java, "portfolio-java :8766", "Java 17+, jar")
            Container(cpp, "portfolio-cpp :8767", "C++ binary")
            Container(sample, "market-sample :8765", "Python")
        }
        Deployment_Node(repo, "~/MyCodeGIT/MxAppsIOS", "git working copy") {
            Container(cli, "MxDataHUB/SRM/srm.py", "Python 3.9+, psycopg2")
        }
        Deployment_Node(kc, "Login Keychain", "macOS") {
            ContainerDb(secrets, "Password items", "MxDataHUB DB password, SRM-postgres, SRM-api keys")
        }
    }
    Deployment_Node(dbhost, "Database host (LAN)", "default 192.168.0.223:5432") {
        ContainerDb(pg, "PostgreSQL database srm", "schema srm")
    }
    Deployment_Node(internet, "Internet") {
        System_Ext(sources, "Data sources", "ISO, Nasdaq Trader, SEC, SSGA, Nasdaq.com, OpenFIGI, FMP, GLEIF")
    }

    Rel(hub, pg, "PostgreSQL protocol, TLS optional")
    Rel(hub, loader, "HTTP")
    Rel(hub, secrets, "Reads / writes")
    Rel(loader, cli, "subprocess")
    Rel(cli, pg, "psycopg2")
    Rel(cli, sources, "HTTPS")
    Rel(cli, secrets, "security CLI")
    Rel(analytics, pg, "psycopg2")
```

## Nodes

| Node | What runs there | How it gets there | Notes |
|---|---|---|---|
| **Mac, /Applications** | `MxDataHUB.app` (`com.k3jdr.MxDataHUB`) | Release build re-signed with the Apple Development certificate (team QC4VX47BJ8), installed with `ditto`, registered with `lsregister`; also zipped to `~/Downloads/MxDataHUB-1.0.zip` | App Sandbox; outgoing network only. Registers `mxdatahub://`. |
| **Mac, loopback** | The five Layer 3 services | `python3 Services/mxservices.py start` (builds the Java jar and C++ binary the first time); optionally `install-agents` writes `~/Library/LaunchAgents/com.k3jdr.mxservices.*.plist` | Logs in `~/Library/Logs/MxServices/`. Outside the sandbox, so they can use files, credentials and packages. |
| **Mac, git working copy** | `srm.py`, migrations, loaders | `~/MyCodeGIT/MxAppsIOS` | srm-loader finds it at `../../MxDataHUB/SRM` (or `--srm-dir`). |
| **Login Keychain** | Secrets | App (*Save password in Keychain*); `security add-generic-password -s SRM-api -a fmp …` for loader keys | Never in the repository; `config.local.json` is git-ignored. |
| **Database host** | PostgreSQL with schema `srm` | `srm.py migrate` | Default `postgres@192.168.0.223:5432/srm`; the app can switch databases on the same server. |
| **Internet** | The data sources | — | Rate limits and plans in `SRM/README.md` and Load History ▸ Sources. |

## Operational notes

- **Order of start-up does not matter**: the app shows *SRM Loader Service Not Running* (with *Check Again*) on Data
  Refresh and service states on Services & Workflows; the security-master screens need only the database.
- **Long loads**: a refresh request waits up to 3 hours (`POST /refresh/{id}` timeout); the service runs one load at
  a time.
- **Testing**: launch arguments `-autoConnect YES -section Portfolios -query AAPL`, connection fields as arguments,
  `PGPASSWORD` in Debug builds.
