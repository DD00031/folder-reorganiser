# Folder Reorganiser

Folder Reorganiser is a native macOS application built with SwiftUI designed to help users declutter directories, manage file structures, and perform batch text edits using a staged, non-destructive workflow.

## Features

### Organization
* **Automated Rules**: Create rules to move files based on extensions or naming patterns (e.g., `*.jpg` -> `Images`).
* **Manual Organization**: Drag and drop files into folders within the sidebar to stage specific moves.
* **Smart Staging**: All changes are virtual first. Review moves in the "Actions" panel before executing them on disk.
* **Conflict Prevention**: Manual drag-and-drop actions take precedence over automated rules.

### Code Editor & Search
* **Batch Find & Replace**: Search and replace text across multiple files simultaneously.
* **Advanced Matching**: Supports Regex, Case Sensitivity, and "Smart Wildcards" (e.g., `<tag>*</tag>`) that match across multiple lines.
* **Scope Control**: Limit operations to specific file extensions or currently selected files.
* **Dedicated Search**: deeply scan files for code snippets or text with line-number precision.

### Workflow
* **Undo/Redo**: Full support for `Cmd+Z` and `Cmd+Shift+Z` to revert staging actions or rule creations.
* **Context Menus**: Right-click files to open them in your default editor, reveal in Finder, or generate rules instantly from their metadata.
* **Virtual Folders**: Create new folders in the staging area that are only created on disk upon execution.

## Requirements

* macOS 13.0 (Ventura) or later.

## Installation

1.  Download the latest release from the [Releases] page.
2.  Unzip the file.
3.  Drag `Folder Reorganiser.app` to your Applications folder.

## Usage

1.  **Open**: Select the root folder you wish to manage.
2.  **Organize**: Use the **Organize** tab to define moving rules or drag files manually in the sidebar.
3.  **Edit**: Use the **Editor** tab to stage bulk text replacements in your HTML/CSS/JS files.
4.  **Search**: Use the **Search** tab to find code blocks or text occurrences.
5.  **Execute**: Click "Execute Changes" to apply all staged moves and edits to the file system.

## License

MIT