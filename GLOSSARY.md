# Glossary

Names used in the code. If you're about to invent a new one for something listed here, use this one instead.

**Tracked repo**: a repository the user chose to watch (`RepoRef` in `AppSettings.trackedRepos`). Add and remove them through `RunStore.track` / `untrack` so the repo list and polling stay in sync.

**Run**: one workflow run from the GitHub API (`WorkflowRun`). A **tracked run** (`TrackedRun`) is a run tagged with its repo.

**Active run**: a run whose status is anything but `completed` (queued, waiting, in progress…). Only active runs get job progress fetched.

**Run progress**: job counts and the current job and step of an active run (`RunProgress`), computed from its jobs.

**Run action**: what the user can do to a run (`RunAction`): cancel, or re-run all or only the failed jobs. The **primary action** is the one-click button: cancel while active, otherwise re-run (failed jobs only if something failed).

**Run event**: a run started or finished between two polls (`RunEvent`). The first poll of a repo only seeds state, so launching doesn't replay old runs.

**Recently finished**: runs that just finished, shown in the notch for 12 seconds (`RecentlyFinished`).

**Auth state**: the single answer to "is the user signed in" (`AuthState`): signed out (no token), token problem (GitHub rejected it), connecting (token saved, user not loaded yet), or signed in.

**Poke**: a request to poll again now instead of waiting out the interval (`RunStore.pokeSoon`). It sticks until the poll loop sees it, so a poke during a refresh isn't lost.

**Notification policy**: decides whether a run event becomes a notification and what it says (`NotificationPolicy`). `Notifier` in the app only delivers it.

**Transport**: the thing that sends one HTTP request (`HTTPTransport`). `URLSessionTransport` is the real one; tests script responses.
