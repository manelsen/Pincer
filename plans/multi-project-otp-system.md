# Objective
Implement a robust, OTP-native multi-project management system. This system will allow users to start, pause, resume, and stop multiple projects independently using unique project IDs, while ensuring total resilience: the user-facing session agent and the background project processes are completely decoupled and can be hot-reloaded or restarted independently.

# Key Files & Context
- `lib/pincer/application.ex`: Register Project Supervisor, Registry, and ensure Blackboard is top-level.
- `lib/pincer/orchestration/blackboard.ex`: Upgrade to a persistent storage (SQLite/DETS) to survive crashes/reloads.
- `lib/pincer/project/server.ex` (New): Independent GenServer for each project, monitoring its own executors.
- `lib/pincer/session/server.ex`: Refactor to use a "Recovery Polling" pattern on startup to catch up with Blackboard updates.

# Implementation Steps
1. **Persistent Blackboard**:
   - Refactor `Pincer.Orchestration.Blackboard` to use a persistent backend (e.g., SQLite via `Pincer.Repo` or DETS).
   - Ensure messages have a `project_id` field for granular filtering.

2. **Project-to-Session Decoupling**:
   - **No Direct Calls**: `Project.Server` MUST NEVER call `Session.Server` directly.
   - **Communication Protocol**: 
     1. `Project.Server` posts status to `Blackboard`.
     2. `Project.Server` broadcasts a "ping" via `Phoenix.PubSub` to `session:{id}`.
     3. `Session.Server` receives the ping and fetches the latest from `Blackboard`.

3. **Hot-Reload & Crash Recovery**:
   - When `Session.Server` starts (or restarts), it initializes its `last_blackboard_id` from the last message it successfully processed (stored in its own session state).
   - It immediately performs a `Blackboard.fetch_new(last_id)` to process any project updates that occurred while it was offline.

4. **Project Supervision**:
   - Projects live under `Pincer.Project.Supervisor`.
   - If a project executor (Coder) dies, the `Project.Server` restarts it.
   - If the `Project.Server` itself dies, its supervisor restarts it, and it resumes the current task by checking its persistent state or the Blackboard history.

5. **Command API (Granular Control)**:
   - `/project start <objective>` -> Spawns `Project.Server`, returns ID.
   - `/project pause/resume/stop <id>` -> Asynchronous control.
   - `/project list` -> Lists all active project processes.

# Verification & Testing
1. **Hot-Reload Test**: Start a project, manually kill the `Session.Server` process, wait for supervisor to restart it, and verify it automatically picks up the latest project updates from the Blackboard.
2. **Persistence Test**: Restart the entire BEAM (or the Blackboard process) and verify that previous project messages are still available.
3. **Concurrency Test**: Run multiple projects and verify that a restart of one project's executor doesn't block the session or other projects.
