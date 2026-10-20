# 05 · Deployment

```mermaid
C4Deployment
    title Deployment — MxJobsWMS

    Deployment_Node(mac, "User's Mac", "macOS 26.6+") {
        Deployment_Node(sandbox, "App Sandbox", "network client, user-selected files, app-scope bookmarks") {
            Container(wms, "MxJobsWMS.app", "SwiftUI DocumentGroup")
            Container(py, "python3 child process", "inherits the sandbox")
        }
        Deployment_Node(files, "User folders", "chosen in Open / Save panels") {
            ContainerDb(jobspaces, "*.jobspace files", "JSON")
            ContainerDb(exports, "PNG and draw.io SVG exports", "files")
        }
        Deployment_Node(loopback, "Loopback 127.0.0.1", "mxservices.py or launchd agents") {
            Container(loader, "srm-loader :8770", "Python")
            Container(analytics, "analytics :8772", "Python")
            Container(java, "portfolio-java :8766", "Java 17")
            Container(cpp, "portfolio-cpp :8767", "C++")
            Container(sample, "market-sample :8765", "Python")
        }
        Deployment_Node(kc, "Login Keychain", "macOS") {
            ContainerDb(keys, "API keys", "com.k3jdr.MxJobsWMS / subscription-id")
        }
        Deployment_Node(hubnode, "/Applications", "") {
            Container(hub, "MxDataHUB.app", "SwiftUI")
        }
    }
    Deployment_Node(lan, "Database host (LAN)", "PostgreSQL") {
        ContainerDb(pg, "srm", "schema srm")
    }
    Deployment_Node(net, "Internet", "") {
        System_Ext(providers, "Provider APIs", "Alpha Vantage, Finnhub, Frankfurter, SEC EDGAR")
    }

    Rel(wms, jobspaces, "Open / Save")
    Rel(wms, exports, "Export")
    Rel(wms, py, "Process")
    Rel(wms, loader, "HTTP")
    Rel(wms, analytics, "HTTP")
    Rel(wms, java, "HTTP")
    Rel(wms, cpp, "HTTP")
    Rel(wms, sample, "HTTP")
    Rel(wms, providers, "HTTPS")
    Rel(wms, keys, "SecItem")
    Rel(analytics, pg, "psycopg2")
    Rel(loader, pg, "psycopg2")
```

## Nodes


| Node                 | What runs there                                                     | How it gets there                                                                                                                                                                                                                                      | Notes                                                                                                                                                                                                             |
| ---------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Mac, App Sandbox** | `MxJobsWMS.app` (`com.k3jdr.MxJobsWMS`), and Python Script children | Release build, re-signed keeping its entitlements (sandbox, network client, user-selected read-write, `files.bookmarks.app-scope`), installed in `/Applications` with `ditto`, registered with `lsregister`; zipped to `~/Downloads/MxJobsWMS-1.0.zip` | Registers `mxjobswms://` and the `.jobspace` type. Python children see only the network and the app's container — not the user's files, `/tmp`, or interpreters and `pip --user` packages under the home folder. |
| **User folders**     | Jobspace files, exports                                             | Open / Save panels (user-selected access)                                                                                                                                                                                                              | Files can be shared: they hold no keys.                                                                                                                                                                           |
| **Loopback**         | Layer 3 services                                                    | `python3 Services/mxservices.py start` / `install-agents`                                                                                                                                                                                              | Outside the sandbox: they may use files, databases, licences and credentials.                                                                                                                                     |
| **Login Keychain**   | API keys                                                            | API Subscriptions ▸ Save Key                                                                                                                                                                                                                          | Re-enter keys on another Mac.                                                                                                                                                                                     |
| **Database host**    | PostgreSQL `srm`                                                    | —                                                                                                                                                                                                                                                     | Reached by the services, never by MxJobsWMS.                                                                                                                                                                      |
| **Internet**         | Provider APIs                                                       | —                                                                                                                                                                                                                                                     | Rate limits per subscription.                                                                                                                                                                                     |

## Run modes as deployment safety


| Setting                                | Effect                                                                                | Default in samples                           |
| ---------------------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------- |
| Layer 3 **Mock**                       | No network, no Python: generated data that passes the step's checks                   | SRM Daily Refresh, Daily Market Data Refresh |
| Layer 3 **Live**                       | Real calls; start the services first                                                  | Active, Passive, Attribution                 |
| Subscription header `X-SRM-Dry-Run: 1` | srm-loader reports commands instead of loading (status still reads the real database) | SRM Daily Refresh                            |
| Layer 1 **Auto-approve**               | Rehearsal without prompts (approvals marked as warnings)                              | —                                           |
| Execution Request                      | Never sends; reports what it would send                                               | all                                          |
