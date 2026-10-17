/*
 * MxDataHUB — C4 model in Structurizr DSL (https://docs.structurizr.com/dsl).
 * The same model as the Mermaid diagrams in this folder. Render with Structurizr Lite:
 *   docker run -it --rm -p 8080:8080 -v "$PWD":/usr/local/structurizr structurizr/lite
 * Recorded 2026-10-17 from the code.
 */
workspace "MxDataHUB" "Security reference master app and the systems around it" {

    !identifiers hierarchical

    model {
        analyst = person "Portfolio / data analyst" "Searches securities, maintains portfolios and benchmarks, checks and refreshes market data."
        steward = person "Data steward" "Owns data quality; approves the automated refresh in MxJobsWMS."

        hub = softwareSystem "MxDataHUB" "Security master screens, portfolios, benchmarks, data refresh and load history." {
            app = container "MxDataHUB.app" "Native macOS app. Sandboxed, outgoing network only." "Swift, SwiftUI, PostgresNIO" {
                shell = component "App shell" "Window, sidebar, Hub menu, Database drop-down, launch arguments, mxdatahub:// routing." "MxDataHUBApp, ContentView"
                screens = component "Security master screens" "DB Connection, Securities, Portfolios, Benchmarks, Load History and their dialogs." "SwiftUI views"
                refresh = component "Data Refresh" "Categories, freshness, Refresh / Refresh All / Preview only." "DataRefreshView, RefreshStore"
                servicesWorkflows = component "Services & Workflows" "Layer 3 services and the MxJobsWMS samples for the selected portfolio." "ServicesWorkflowsView"
                store = component "SRMStore" "Connection state, selections, row models and every SQL query and change." "Observable class"
                pg = component "PostgresService" "PostgresNIO connection; parameterised SQL with text binds." "Swift"
                keychain = component "Keychain" "Database password per user@host:port/database." "Security framework"
                quickHelp = component "HubQuickHelp" "Quick Help text for screens, selection and controls." "Swift"
                shared = component "Shared code" "AppLinks, ServiceCatalog, ServicesView, QuickHelp (../Shared)." "Swift"
            }
            cli = container "srm.py" "Migrations and loaders, one module per source; upserts; load audit." "Python 3.9+, psycopg2"
            db = container "SRM schema" "Securities, identifiers with validity, benchmarks and portfolios as dated snapshots, prices, load audit; rules as constraints and SQL functions." "PostgreSQL" "Database"
        }

        services = softwareSystem "Layer 3 services" "Local HTTP services on 127.0.0.1, shared with MxJobsWMS." {
            loader = container "srm-loader" "Data categories and freshness; runs srm.py loaders one at a time; status and quality." "Python HTTP :8770"
            analytics = container "analytics" "Optimization inputs, attribution." "Python HTTP :8772"
            java = container "portfolio-java" "Active optimization." "Java HTTP :8766"
            cpp = container "portfolio-cpp" "Index tracking and risk." "C++ HTTP :8767"
        }

        wms = softwareSystem "MxJobsWMS" "Scheduled, checked and approved workflows over the security master." "External"
        sources = softwareSystem "Data sources" "ISO 20022 MICs, SIX ISO 4217, Nasdaq Trader, SEC EDGAR, SSGA SPDR, Nasdaq.com, OpenFIGI, FMP, GLEIF." "External"
        loginKeychain = softwareSystem "macOS login Keychain" "Password items." "External"

        analyst -> hub.app "Uses"
        steward -> wms "Approves refresh runs"
        hub.app -> hub.db "Queries and single-statement changes" "PostgreSQL protocol"
        hub.app -> services.loader "GET /categories, POST /refresh/{category}" "HTTP JSON"
        hub.app -> services.analytics "GET /health" "HTTP"
        hub.app -> services.java "GET /health" "HTTP"
        hub.app -> services.cpp "GET /health" "HTTP"
        services.loader -> hub.cli "Runs srm.py load" "subprocess"
        hub.cli -> hub.db "Migrates, upserts, audits" "psycopg2"
        hub.cli -> sources "Downloads" "HTTPS"
        services.analytics -> hub.db "Reads" "psycopg2"
        hub.app -> wms "Opens a workflow for a portfolio or benchmark" "mxjobswms:// URL"
        wms -> hub.app "Opens a portfolio, benchmark or screen" "mxdatahub:// URL"
        hub.app -> loginKeychain "Saves and reads the password"

        hub.app.shell -> hub.app.screens "Shows the selected screen"
        hub.app.shell -> hub.app.refresh "Shows"
        hub.app.shell -> hub.app.servicesWorkflows "Shows"
        hub.app.screens -> hub.app.store "Binds to state, calls async actions"
        hub.app.store -> hub.app.pg "SQL with text binds"
        hub.app.pg -> hub.db "PostgreSQL protocol"
        hub.app.store -> hub.app.keychain "Password"
        hub.app.keychain -> loginKeychain "SecItem API"
        hub.app.refresh -> services.loader "HTTP JSON"
        hub.app.servicesWorkflows -> hub.app.shared "ServicesView, SampleGalleryView, AppLink"
        hub.app.shared -> wms "mxjobswms:// URL"
        hub.app.screens -> hub.app.quickHelp "Quick Help items"

        live = deploymentEnvironment "Desk" {
            deploymentNode "User's Mac" "" "macOS 26.6+" {
                deploymentNode "/Applications" {
                    containerInstance hub.app
                }
                deploymentNode "Loopback 127.0.0.1" "" "mxservices.py or launchd" {
                    containerInstance services.loader
                    containerInstance services.analytics
                    containerInstance services.java
                    containerInstance services.cpp
                }
                deploymentNode "~/MyCodeGIT/MXcodeIDE" {
                    containerInstance hub.cli
                }
            }
            deploymentNode "Database host (LAN)" "" "PostgreSQL, default 192.168.0.223:5432" {
                containerInstance hub.db
            }
        }
    }

    views {
        systemContext hub "SystemContext" {
            include *
            autolayout lr
        }
        container hub "Containers" {
            include *
            include services.loader services.analytics services.java services.cpp
            autolayout lr
        }
        component hub.app "Components" {
            include *
            autolayout lr
        }
        deployment hub live "Deployment" {
            include *
            autolayout lr
        }
        styles {
            element "Person" {
                shape person
                background #08427b
                color #ffffff
            }
            element "Software System" {
                background #1168bd
                color #ffffff
            }
            element "External" {
                background #999999
                color #ffffff
            }
            element "Container" {
                background #438dd5
                color #ffffff
            }
            element "Component" {
                background #85bbf0
                color #000000
            }
            element "Database" {
                shape cylinder
            }
        }
    }
}
