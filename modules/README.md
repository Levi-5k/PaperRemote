# paperGIF modules

The macOS and Windows companions discover modules from [`index.json`](index.json) on GitHub. A module is a data-only JSON manifest containing controls that already use the paperGIF remote profile action model. Modules do not run downloaded application code.

## Publish a module

1. Copy [`media-controls.json`](media-controls.json) and give the file and module a unique lowercase, hyphenated ID.
2. Add one or more controls. A module may also include optional page templates. Every control and page must satisfy the [module manifest schema](../protocol/module-manifest-v1.schema.json) and its embedded remote profile schemas.
3. Add the module metadata and relative manifest path to [`index.json`](index.json).
4. Commit and push both files to the repository's `main` branch.
5. Open **Modules** in either computer companion and press refresh.

Nothing is installed automatically. Each module has its own **Install** button. Installing downloads the manifest over HTTPS and saves it locally; its controls then become available individually under **Add Controls** without changing any page. If the manifest includes page templates, the installed module also shows an explicit **Add Page** button. Added pages and controls receive fresh IDs, so the same template can be added more than once.

Changing a module's `version` makes installed companions offer the updated download. Keep manifests below 512 KB and no larger than 24 controls.