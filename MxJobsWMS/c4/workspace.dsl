/*
 * MxJobsWMS — C4 model in Structurizr DSL (https://docs.structurizr.com/dsl).
 * The same model as the Mermaid diagrams in this folder. Render with Structurizr Lite:
 *   docker run -it --rm -p 8080:8080 -v "$PWD":/usr/local/structurizr structurizr/lite
 * Recorded 2026-10-17 from the code.
 */
workspace "MxJobsWMS" "Three-layer workflow designer and runner, and the systems around it" {

    !identifiers hierarchical

    model {
        pm = person "Portfolio manager" "Runs optimization, tracking and attribution workflows; approves rebalances."
        steward = person "Data steward" "Runs the security master refresh; approves the daily report and backfills."
        designer = person "Workflow designer / developer" "Builds jobspaces, subscriptions and Layer 3 services."

        wms = softwareSystem "MxJobsWMS" "Design, check, run and debug three-layer workflows saved as jobspace files." {
            app = container "MxJobsWMS.app" "Swim-lane editor, inspector, validation, run engine with debugger, API and Python runners. Sandboxed." "Swift, SwiftUI DocumentGroup" {
                shell = component "App and commands" "Document windows, menus, utility windows, mxjobswms:// links." "MxJobsWMSApp, JobspaceCommands, AppDelegate"
                editor = component "Editor window" "Palette, run bar, canvas, console, inspector; selection, zoom, panels." "ContentView, EditorState"
                canvas = component "Swim-lane canvas" "Three lanes; nodes, links, run state; drag, link, select, zoom; export menu." "DiagramCanvas, NodeView"
                palette = component "Palette" "Node kinds by layer; Layer 3 services with state." "PaletteView"
                inspector = component "Inspector" "Node, link and jobspace properties; Test Call, Run Script, Open Project." "InspectorView"
                subscriptions = component "API Subscriptions" "Subscriptions, auth styles, keys, source projects; key guides." "SubscriptionsDialog, KeyHelp"
                validator = component "Validator" "Problems: approvals before execution, subscriptions, keys, paths, links, URLs." "Validation.swift"
                engine = component "Run engine" "Dependency order across layers; per-layer actions; breakpoints, Step, prompts; exception policies." "RunEngine, RunViews"
                apiRunner = component "API runner" "Requests with substitutions and auth; expected outcome checks; Test Key, Test Call." "ApiTester"
                pythonRunner = component "Python runner" "Interpreter lookup; JSON stdin and stdout; timeout." "PythonRunner"
                jobspaceModel = component "Jobspace model" "Codable model with defaults; editing operations; file I/O." "JobspaceModel, JobspaceDocument"
                samples = component "Samples" "The five sample jobspaces, for a portfolio and benchmark." "SampleLibrary, SampleJobspace, SRMSampleJobspace, PortfolioSamples"
                diagramExport = component "Diagram export" "PNG and draw.io SVG." "DiagramExport"
                projects = component "Project opener" "IDE URL schemes; security-scoped bookmarks." "ProjectOpener"
                keychain = component "Keychain" "Key per subscription." "Keychain, KeychainChanges"
                quickHelp = component "JobsQuickHelp" "Quick Help text." "Swift"
                shared = component "Shared code" "AppLinks, ServiceCatalog, ServicesView, QuickHelp (../Shared)." "Swift"
            }
            files = container "Jobspace files" "format mxjobspace v1: subscriptions, nodes, links, run settings. No keys." "*.jobspace JSON" "Database"
            python = container "Python Script process" "One process per step run, inside the app sandbox." "python3"
        }

        services = softwareSystem "Layer 3 services" "Local HTTP services on 127.0.0.1, shared with MxDataHUB." {
            loader = container "srm-loader" "/load/{loader}, /status." "Python HTTP :8770"
            analytics = container "analytics" "/inputs, /inputs/{id}, /attribution." "Python HTTP :8772"
            java = container "portfolio-java" "/optimize/active, /optimize." "Java 17 HTTP :8766"
            cpp = container "portfolio-cpp" "/optimize/tracking, /risk, /optimize." "C++ HTTP :8767"
            sample = container "market-sample" "/quote, /history, /indicators." "Python HTTP :8765"
        }

        providers = softwareSystem "Provider APIs" "Alpha Vantage, Finnhub, Frankfurter FX, SEC EDGAR." "External"
        hub = softwareSystem "MxDataHUB" "The security master app." "External"
        srmdb = softwareSystem "SRM database" "PostgreSQL schema srm." "External"
        loginKeychain = softwareSystem "macOS login Keychain" "API keys per subscription." "External"
        ides = softwareSystem "IDEs" "VS Code, IntelliJ IDEA, CLion, Xcode, Finder." "External"

        pm -> wms.app "Runs workflows, approves"
        steward -> wms.app "Runs refresh, approves"
        designer -> wms.app "Designs jobspaces and subscriptions"
        wms.app -> wms.files "Opens, saves, exports" "FileDocument"
        wms.app -> wms.python "Runs Python Script steps" "Process, JSON stdin and stdout"
        wms.app -> services.loader "API Data Read" "HTTP JSON"
        wms.app -> services.analytics "API Data Read" "HTTP JSON"
        wms.app -> services.java "API Data Read" "HTTP JSON"
        wms.app -> services.cpp "API Data Read" "HTTP JSON"
        wms.app -> services.sample "API Data Read" "HTTP JSON"
        wms.app -> providers "API Data Read, Test Key, Test Call" "HTTPS"
        wms.app -> loginKeychain "Keys" "Security framework"
        wms.app -> hub "Opens a screen" "mxdatahub:// URL"
        hub -> wms.app "Opens a sample for a portfolio or benchmark" "mxjobswms:// URL"
        wms.app -> ides "Open Project in…" "URL schemes or bookmarks"
        services.java -> services.analytics "GET inputsUrl" "HTTP"
        services.cpp -> services.analytics "GET inputsUrl" "HTTP"
        services.analytics -> srmdb "Reads" "psycopg2"
        services.loader -> srmdb "srm.py loads" "psycopg2"

        wms.app.shell -> wms.app.editor "One per document window"
        wms.app.shell -> wms.app.samples "New from Sample, links"
        wms.app.shell -> wms.app.shared "ServicesView, SampleGalleryView, AppLink"
        wms.app.editor -> wms.app.canvas "Hosts"
        wms.app.editor -> wms.app.palette "Hosts"
        wms.app.editor -> wms.app.inspector "Hosts"
        wms.app.editor -> wms.app.engine "Owns one"
        wms.app.editor -> wms.app.validator "Checks on every change"
        wms.app.canvas -> wms.app.jobspaceModel "Edits nodes and links"
        wms.app.canvas -> wms.app.diagramExport "Save as PNG or draw.io SVG"
        wms.app.inspector -> wms.app.jobspaceModel "Edits settings"
        wms.app.inspector -> wms.app.apiRunner "Test Call"
        wms.app.inspector -> wms.app.pythonRunner "Run Script"
        wms.app.inspector -> wms.app.projects "Open Project in…"
        wms.app.engine -> wms.app.apiRunner "API Data Read steps"
        wms.app.engine -> wms.app.pythonRunner "Python Script steps"
        wms.app.apiRunner -> wms.app.keychain "Key for the subscription"
        wms.app.subscriptions -> wms.app.keychain "Save / Remove Key"
        wms.app.jobspaceModel -> wms.files "Read / write"
        wms.app.pythonRunner -> wms.python "Process"
        wms.app.apiRunner -> services.analytics "HTTP"
        wms.app.apiRunner -> providers "HTTPS"
        wms.app.keychain -> loginKeychain "SecItem API"
        wms.app.palette -> wms.app.quickHelp "Quick Help items"

        live = deploymentEnvironment "Desk" {
            deploymentNode "User's Mac" "" "macOS 26.6+" {
                deploymentNode "App Sandbox" "" "network client, user-selected files, bookmarks" {
                    containerInstance wms.app
                    containerInstance wms.python
                }
                deploymentNode "User folders" {
                    containerInstance wms.files
                }
                deploymentNode "Loopback 127.0.0.1" "" "mxservices.py or launchd" {
                    containerInstance services.loader
                    containerInstance services.analytics
                    containerInstance services.java
                    containerInstance services.cpp
                    containerInstance services.sample
                }
            }
        }
    }

    views {
        systemContext wms "SystemContext" {
            include *
            autolayout lr
        }
        container wms "Containers" {
            include *
            include services.loader services.analytics services.java services.cpp services.sample
            autolayout lr
        }
        component wms.app "Components" {
            include *
            autolayout lr
        }
        deployment wms live "Deployment" {
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
