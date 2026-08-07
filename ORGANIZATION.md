# Local data organization

Source code belongs in this repository. Private runtime state belongs under `~/Jarvis` and must never be committed.

```text
~/Jarvis/
├── App/                 installed local app
├── Data/                database, configuration, logs, runtime state, helpers
├── Information/
│   ├── Screenshots/
│   ├── Memory Exports/
│   ├── Inbox/
│   ├── Personal Notes/
│   ├── Project Notes/
│   └── Trading/
│       ├── Chart Reviews/
│       └── Trade Journal/
└── Models/              local model weights
```

`Data`, `Information`, and `Models` may contain sensitive material. The public-repository scan rejects databases, audio, model weights, encrypted backups, private absolute paths, and common token formats.

The repository's `build/`, `.venv/`, generated App Intents lists, and package metadata are also local artifacts. Rebuild them from source instead of editing or publishing them.
