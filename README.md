# WenzAgent

Pure Dart library for AI Agent management, LAN communication, and RPC.

## Features

- **Agent System** — Create and manage AI agents (employees) with configurable LLM backends, tool calling, and state management
- **LAN Communication** — Device discovery and messaging over local area network via WebSocket
- **RPC Framework** — Remote procedure call layer for inter-device communication
- **Skill System** — Extensible skill architecture supporting MCP (Model Context Protocol), folder-based prompts, and configuration-driven skills
- **Persistence** — SQLite-backed storage for messages, sessions, and agent state
- **Task Scheduling** — Cron-based task scheduler for automated agent operations

## Architecture

```
wenzagent/
├── lib/src/
│   ├── agent/          # Agent interface, implementation, proxy, processor, LLM adapters
│   ├── device/         # Device connection management and state
│   ├── entity/         # Data models (LanMessage, LanClient, HostRpcRequest)
│   ├── host/           # Host server with session management
│   ├── lan/            # LAN discovery, host/client services, chunk transfer
│   ├── persistence/    # SQLite database, stores, migrations
│   ├── rpc/            # Remote call protocol, server, config
│   ├── scheduler/      # Cron expression parser, task scheduler
│   ├── service/        # Business services (EmployeeManager, SessionManager, etc.)
│   ├── shared/         # ChatMessage, message mappers
│   ├── skill/          # Skill system (MCP, folder, config)
│   └── utils/          # Utilities
├── example/            # Usage examples
├── doc/                # Design documents
└── test/               # Tests
```

## Quick Start

See [QUICKSTART.md](QUICKSTART.md) for environment setup and running tests.

## Documentation

- [Skill System Design](doc/skill_system_design.md)
- [Cached Agent Proxy Guide](doc/cached-agent-proxy-guide.md)
- [Tool Call Status Frontend Guide](doc/tool-call-status-frontend-guide.md)

## License

See [LICENSE](LICENSE).
