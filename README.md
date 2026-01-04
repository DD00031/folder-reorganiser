# Folder Reorganiser

Folder Reorganiser is a native macOS application built with SwiftUI designed to help users quickly declutter directories using automated rules and manual organization.

## Features

* **Automated Rules**: Create rules to move files based on file extensions or name patterns (e.g., move all `.jpg` and `.png` files to an "Images" folder).
* **Staged Execution**: All changes are virtual (staged) first. No files are moved on disk until you click "Execute Changes."
* **Drag & Drop**: Manually drag files into folders within the sidebar to stage moves.
* **Virtual Folders**: Create new folders in the staging area that are created on disk only upon execution.
* **Undo/Redo**: Full support for undoing actions before execution.
* **Smart Conflict Handling**: Prevents rules from overwriting manual file moves.

## Requirements

* macOS 13.0 (Ventura) or later.

## Installation

1.  Download the latest release from the [Releases](https://github.com/DD00031/folder-reorganiser/releases) page.
2.  Unzip the file.
3.  Drag `Folder Reorganiser.app` to your Applications folder.

## Build from Source

1.  Clone the repository.
2.  Open `Folder Reorganiser.xcodeproj` in Xcode.
3.  Ensure the target is set to your Mac.
4.  Press `Cmd+R` to build and run.

## Usage

1.  **Open**: Select the root folder you wish to organize.
2.  **Create Rules**: Use the top-right panel to define rules (e.g., Extension: `jpg` -> Folder: `Photos`).
3.  **Review**: Check the "Actions" panel to see a preview of file moves.
4.  **Execute**: Click "Execute Changes" to apply the moves to your actual file system.

## License
folder-reorganiser is available under the GPL-3.0 license.