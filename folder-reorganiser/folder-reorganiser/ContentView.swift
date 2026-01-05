import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Enums & Models

enum AppMode: String, CaseIterable {
    case organize = "Organize"
    case editor = "Editor"
    case search = "Search"
}

enum RuleType: String, CaseIterable, Identifiable {
    case extensionMatch = "Extension"
    case nameContains = "Name Contains"
    var id: String { self.rawValue }
}

enum EditorScope: String, CaseIterable {
    case selectedFiles = "Selected Files"
    case allFiles = "All Files in Root"
}

struct OrganizationRule: Identifiable, Hashable {
    let id = UUID()
    let type: RuleType
    let criteria: String
    let targetFolder: String
}

struct SearchResult: Identifiable, Hashable {
    let id = UUID()
    let fileID: UUID
    let fileName: String
    let filePath: String
    let lineContent: String
    let lineNumber: Int
    let url: URL
}

struct FileNode: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var name: String
    let isDirectory: Bool
    var children: [FileNode]?
    
    var destinationURL: URL
    var isVirtual: Bool = false
    
    // Status Flags
    var isManuallyMoved: Bool = false
    var isImplicitRuleFolder: Bool = false
    var isContentModified: Bool = false
    var contentMatchCount: Int = 0
    
    var isMoved: Bool { return url != destinationURL }
    
    init(url: URL, name: String, isDirectory: Bool, children: [FileNode]? = nil, destinationURL: URL? = nil, isVirtual: Bool = false, isManuallyMoved: Bool = false, isImplicitRuleFolder: Bool = false, isContentModified: Bool = false, contentMatchCount: Int = 0) {
        self.id = UUID()
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.destinationURL = destinationURL ?? url
        self.isVirtual = isVirtual
        self.isManuallyMoved = isManuallyMoved
        self.isImplicitRuleFolder = isImplicitRuleFolder
        self.isContentModified = isContentModified
        self.contentMatchCount = contentMatchCount
    }
}

// MARK: - View Model

class OrganizerViewModel: ObservableObject {
    @Published var appMode: AppMode = .organize
    
    @Published var rootURL: URL?
    @Published var rootPathString: String = ""
    @Published var fileTree: [FileNode] = []
    
    @Published var stagedChanges: [FileNode] = []
    
    @Published var statusMessage: String = "Ready."
    @Published var isProcessing = false
    
    // Selections
    @Published var selectedIDs: Set<UUID> = []
    @Published var actionSelectedIDs: Set<UUID> = []
    
    // MARK: Organiser Inputs
    @Published var addedRules: [OrganizationRule] = []
    @Published var newRuleType: RuleType = .extensionMatch
    @Published var newRuleCriteria: String = ""
    @Published var newRuleFolder: String = ""
    
    // MARK: Editor Inputs
    @Published var editorFindText: String = ""
    @Published var editorReplaceText: String = ""
    @Published var editorScope: EditorScope = .selectedFiles
    @Published var editorTargetExtensions: String = ""
    @Published var editorIsRegex: Bool = false
    @Published var editorIsWildcard: Bool = false
    @Published var editorCaseSensitive: Bool = false
    
    @Published var pendingContentEdits: [UUID: String] = [:]
    
    // MARK: Search Inputs
    @Published var searchText: String = ""
    @Published var searchResults: [SearchResult] = []
    @Published var searchIsRegex: Bool = false
    @Published var searchIsWildcard: Bool = true
    @Published var searchCaseSensitive: Bool = false
    
    var availableFolders: [String] {
        getAllFolderNames(nodes: fileTree)
    }
    
    // MARK: - Actions
    
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Select Root"
        if panel.runModal() == .OK, let url = panel.url {
            self.rootURL = url
            self.rootPathString = url.path
            refreshTree()
        }
    }
    
    func refreshTree() {
        guard let root = rootURL else { return }
        if self.statusMessage != "Changes executed" { self.statusMessage = "Scanning..." }
        DispatchQueue.global(qos: .userInteractive).async {
            let tree = self.buildTree(from: root)
            DispatchQueue.main.async {
                self.fileTree = tree
                self.applyRules()
                self.restoreContentEdits()
                if self.statusMessage == "Scanning..." { self.statusMessage = "Ready." }
            }
        }
    }
    
    func clearSelection() {
        DispatchQueue.main.async { self.selectedIDs = [] }
    }
    
    // MARK: - Action Management
    
    func revertSelectedActions(undoManager: UndoManager?) {
        guard !actionSelectedIDs.isEmpty else { return }
        for id in actionSelectedIDs {
            updateTree(nodes: &fileTree, targetID: id) { node in
                node.destinationURL = node.url
                node.isManuallyMoved = false
                node.isContentModified = false
                node.contentMatchCount = 0
                self.pendingContentEdits.removeValue(forKey: node.id)
            }
        }
        actionSelectedIDs.removeAll()
        recalculateStagedChanges()
        statusMessage = "Reverted selected actions."
    }
    
    func populateRuleFromAction() {
        guard actionSelectedIDs.count == 1, let id = actionSelectedIDs.first else { return }
        guard let node = findNode(id: id, nodes: stagedChanges) else { return }
        if node.isMoved && !node.isDirectory {
            self.newRuleType = .extensionMatch
            self.newRuleCriteria = node.url.pathExtension
            self.newRuleFolder = node.destinationURL.deletingLastPathComponent().lastPathComponent
            self.appMode = .organize
        }
    }
    
    func populateRuleFromSelection(clickedID: UUID) {
        if !selectedIDs.contains(clickedID) { selectedIDs = [clickedID] }
        if selectedIDs.count > 1 {
            let names = selectedIDs.compactMap { findNode(id: $0, nodes: fileTree)?.name }
            self.newRuleType = .nameContains
            self.newRuleCriteria = names.joined(separator: ", ")
        } else {
            if let node = findNode(id: clickedID, nodes: fileTree) {
                self.newRuleType = .extensionMatch
                self.newRuleCriteria = node.url.pathExtension
            }
        }
        self.newRuleFolder = ""
        self.appMode = .organize
    }
    
    // MARK: - Rule Logic
    
    func addRule(undoManager: UndoManager?) {
        let cleanCriteria = newRuleCriteria.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFolder = newRuleFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCriteria.isEmpty, !cleanFolder.isEmpty else { return }
        let rule = OrganizationRule(type: newRuleType, criteria: cleanCriteria, targetFolder: cleanFolder)
        
        undoManager?.registerUndo(withTarget: self) { vm in
            if let index = vm.addedRules.firstIndex(of: rule) {
                vm.addedRules.remove(at: index)
                vm.applyRules()
                undoManager?.registerUndo(withTarget: vm) { target in
                    target.newRuleType = rule.type; target.newRuleCriteria = rule.criteria; target.newRuleFolder = rule.targetFolder
                    target.addRule(undoManager: undoManager)
                }
            }
        }
        addedRules.append(rule)
        applyRules()
        DispatchQueue.main.async { self.newRuleCriteria = ""; self.newRuleFolder = "" }
    }
    
    func applyRules() {
        guard let root = rootURL else { return }
        resetAutoDestinations(nodes: &fileTree)
        updateTree(nodes: &fileTree) { node in
            if node.isDirectory || node.isManuallyMoved { return }
            for rule in addedRules {
                var matches = false
                if rule.type == .extensionMatch {
                    let rawExtensions = rule.criteria.components(separatedBy: .whitespacesAndNewlines).flatMap { $0.components(separatedBy: ",") }
                    let targetExtensions = rawExtensions.compactMap { $0.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces).lowercased() }
                    matches = targetExtensions.contains(node.url.pathExtension.lowercased())
                } else if rule.type == .nameContains {
                    let rawNames = rule.criteria.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if rawNames.count > 1 {
                        matches = rawNames.contains(where: { node.name == $0 || node.name.localizedCaseInsensitiveContains($0) })
                    } else { matches = node.name.localizedCaseInsensitiveContains(rule.criteria) }
                }
                if matches {
                    let targetDir = root.appendingPathComponent(rule.targetFolder)
                    node.destinationURL = targetDir.appendingPathComponent(node.name)
                    return
                }
            }
        }
        recalculateStagedChanges()
    }
    
    // MARK: - Smart Regex Generation
    
    private func smartWildcardRegex(from text: String, caseSensitive: Bool) -> NSRegularExpression? {
        var pattern = NSRegularExpression.escapedPattern(for: text)
        pattern = pattern.replacingOccurrences(of: " ", with: "[\\s\\r\\n]*")
        pattern = pattern.replacingOccurrences(of: "\n", with: "[\\s\\r\\n]*")
        pattern = pattern.replacingOccurrences(of: "\\*", with: "(.*?)")
        
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive, .dotMatchesLineSeparators]
        return try? NSRegularExpression(pattern: pattern, options: options)
    }
    
    // MARK: - Search Logic
    
    func performSearch() {
        guard !searchText.isEmpty else { return }
        guard let root = rootURL else { return }
        isProcessing = true
        searchResults = []
        statusMessage = "Searching..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [SearchResult] = []
            let allNodes = self.collectNodesForEditor(scope: .allFiles, selectedIDs: [], nodes: self.fileTree)
            
            for node in allNodes {
                do {
                    let content = try String(contentsOf: node.url, encoding: .utf8)
                    var regex: NSRegularExpression? = nil
                    
                    if self.searchIsWildcard {
                        regex = self.smartWildcardRegex(from: self.searchText, caseSensitive: self.searchCaseSensitive)
                    } else if self.searchIsRegex {
                        let options: NSRegularExpression.Options = self.searchCaseSensitive ? [] : [.caseInsensitive, .dotMatchesLineSeparators]
                        regex = try? NSRegularExpression(pattern: self.searchText, options: options)
                    }
                    
                    if let r = regex {
                        let matches = r.matches(in: content, options: [], range: NSRange(content.startIndex..., in: content))
                        for match in matches {
                            if let range = Range(match.range, in: content) {
                                let matchStr = String(content[range])
                                let prefix = content[..<range.lowerBound]
                                let lineNum = prefix.filter({ $0 == "\n" }).count + 1
                                
                                results.append(SearchResult(
                                    fileID: node.id,
                                    fileName: node.name,
                                    filePath: node.url.path.replacingOccurrences(of: root.path, with: ""),
                                    lineContent: matchStr,
                                    lineNumber: lineNum,
                                    url: node.url
                                ))
                            }
                        }
                    } else {
                        let lines = content.components(separatedBy: .newlines)
                        for (idx, line) in lines.enumerated() {
                            let match = self.searchCaseSensitive ? line.contains(self.searchText) : line.localizedCaseInsensitiveContains(self.searchText)
                            if match {
                                results.append(SearchResult(fileID: node.id, fileName: node.name, filePath: "", lineContent: line.trimmingCharacters(in: .whitespaces), lineNumber: idx + 1, url: node.url))
                            }
                        }
                    }
                } catch {}
            }
            DispatchQueue.main.async {
                self.searchResults = results
                self.isProcessing = false
                self.statusMessage = "Found \(results.count) matches."
            }
        }
    }
    
    // MARK: - Editor Logic
    
    func stageContentEdit() {
        guard !editorFindText.isEmpty else { statusMessage = "Error: Find field is empty."; return }
        isProcessing = true
        statusMessage = "Scanning..."
        let targetExts = editorTargetExtensions.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ".", with: "") }.filter { !$0.isEmpty }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var affectedIDs: [UUID] = []
            let targetNodes = self.collectNodesForEditor(scope: self.editorScope, selectedIDs: self.selectedIDs, nodes: self.fileTree)
            
            for node in targetNodes {
                if !targetExts.isEmpty && !targetExts.contains(node.url.pathExtension.lowercased()) { continue }
                do {
                    let content = try String(contentsOf: node.url, encoding: .utf8)
                    var newContent = content
                    var matchCount = 0
                    
                    if self.editorIsWildcard {
                        if let regex = self.smartWildcardRegex(from: self.editorFindText, caseSensitive: self.editorCaseSensitive) {
                            var regexReplace = self.editorReplaceText
                            var captureIndex = 1
                            while regexReplace.contains("*") {
                                if let range = regexReplace.range(of: "*") {
                                    regexReplace.replaceSubrange(range, with: "$\(captureIndex)")
                                    captureIndex += 1
                                }
                            }
                            let range = NSRange(content.startIndex..., in: content)
                            matchCount = regex.numberOfMatches(in: content, options: [], range: range)
                            if matchCount > 0 {
                                newContent = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: regexReplace)
                            }
                        }
                    } else if self.editorIsRegex {
                        let options: NSRegularExpression.Options = self.editorCaseSensitive ? [] : [.caseInsensitive]
                        if let regex = try? NSRegularExpression(pattern: self.editorFindText, options: options) {
                            let range = NSRange(content.startIndex..., in: content)
                            matchCount = regex.numberOfMatches(in: content, options: [], range: range)
                            if matchCount > 0 {
                                newContent = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: self.editorReplaceText)
                            }
                        }
                    } else {
                        let options: String.CompareOptions = self.editorCaseSensitive ? [] : [.caseInsensitive]
                        let ranges = content.ranges(of: self.editorFindText, options: options)
                        matchCount = ranges.count
                        if matchCount > 0 {
                            newContent = content.replacingOccurrences(of: self.editorFindText, with: self.editorReplaceText, options: options)
                        }
                    }
                    
                    if matchCount > 0 {
                        let count = matchCount
                        DispatchQueue.main.async {
                            self.pendingContentEdits[node.id] = newContent
                            self.updateTree(nodes: &self.fileTree, targetID: node.id) {
                                $0.isContentModified = true
                                $0.contentMatchCount = count
                            }
                        }
                        affectedIDs.append(node.id)
                    }
                } catch {}
            }
            DispatchQueue.main.async { self.isProcessing = false; self.statusMessage = "Staged \(affectedIDs.count) files."; self.recalculateStagedChanges() }
        }
    }
    
    // MARK: - File Ops (Undo/Redo)
    
    func createVirtualFolder(name: String, parentID: UUID?, undoManager: UndoManager?) {
        guard let root = rootURL else { return }
        let parentURL = findURL(for: parentID, in: fileTree) ?? root
        let virtualURL = parentURL.appendingPathComponent(name)
        let newNode = FileNode(url: virtualURL, name: name, isDirectory: true, children: [], destinationURL: virtualURL, isVirtual: true)
        
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.refreshTree()
            undoManager?.registerUndo(withTarget: vm) { target in
                target.createVirtualFolder(name: name, parentID: parentID, undoManager: undoManager)
            }
        }
        
        if let pid = parentID { updateTree(nodes: &fileTree, targetID: pid) { parent in if parent.children == nil { parent.children = [] }; parent.children?.append(newNode) } }
        else { fileTree.append(newNode) }
        recalculateStagedChanges()
    }
    
    func moveItems(ids: [UUID], toFolder node: FileNode, undoManager: UndoManager?) {
        guard node.isDirectory else { return }
        let currentDestinations = findDestinations(for: ids, in: fileTree)
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.restoreDestinations(originalDestinations: currentDestinations)
            undoManager?.registerUndo(withTarget: vm) { target in
                target.moveItems(ids: ids, toFolder: node, undoManager: undoManager)
            }
        }
        for id in ids {
            updateTree(nodes: &fileTree, targetID: id) { item in
                if node.destinationURL.path.contains(item.url.path) { return }
                item.destinationURL = node.destinationURL.appendingPathComponent(item.name)
                item.isManuallyMoved = true
            }
        }
        recalculateStagedChanges()
    }
    
    func renameNode(_ id: UUID, to newName: String, undoManager: UndoManager?) {
        updateTree(nodes: &fileTree, targetID: id) { node in
            let oldName = node.name
            undoManager?.registerUndo(withTarget: self) { vm in
                vm.renameNode(id, to: oldName, undoManager: undoManager)
                undoManager?.registerUndo(withTarget: vm) { target in
                    target.renameNode(id, to: newName, undoManager: undoManager)
                }
            }
            node.name = newName
            node.destinationURL = node.destinationURL.deletingLastPathComponent().appendingPathComponent(newName)
        }
        recalculateStagedChanges()
    }
    
    func createNewFolderFromSelection(undoManager: UndoManager?) {
        let name = "New Folder"
        var targetParentID: UUID? = nil
        if selectedIDs.count == 1, let selectedID = selectedIDs.first {
            if let node = findNode(id: selectedID, nodes: fileTree) {
                targetParentID = node.isDirectory ? node.id : findParentID(for: node.id, nodes: fileTree)
            }
        }
        createVirtualFolder(name: name, parentID: targetParentID, undoManager: undoManager)
    }
    
    // MARK: - EXECUTION (UPDATED with References Fix)
    
    func execute() {
        guard let root = rootURL else { return }
        isProcessing = true
        statusMessage = "Executing..."
        let fileManager = FileManager.default
        let changesToProcess = self.stagedChanges
        
        DispatchQueue.global(qos: .userInitiated).async {
            var errorCount = 0
            
            // 0. Build global file map (Original -> New) BEFORE moving anything
            // This ensures we know where every file ends up to resolve references later
            let allFilesMap = self.buildGlobalFileMap(nodes: self.fileTree)
            
            // 1. Create Directories
            let parentFolders = Set(changesToProcess.map { $0.destinationURL.deletingLastPathComponent() })
            for folder in parentFolders { try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil) }
            
            // 2. Move Files & Apply Manual Edits
            for node in changesToProcess {
                do {
                    if node.isMoved {
                        if node.isDirectory {
                            if node.isVirtual || node.isImplicitRuleFolder { try? fileManager.createDirectory(at: node.destinationURL, withIntermediateDirectories: true, attributes: nil) }
                            else { try fileManager.moveItem(at: node.url, to: node.destinationURL) }
                        } else {
                            if fileManager.fileExists(atPath: node.url.path) { try fileManager.moveItem(at: node.url, to: node.destinationURL) }
                        }
                    }
                    if node.isContentModified, let newContent = self.pendingContentEdits[node.id] {
                        let targetURL = node.destinationURL
                        try newContent.write(to: targetURL, atomically: true, encoding: .utf8)
                    }
                } catch { errorCount += 1 }
            }
            
            // 3. Update HTML References (Restored Feature)
            // We iterate through the map to find text files and update their content based on new locations
            let textExtensions = ["html", "htm", "css", "js", "php"]
            
            for (_, newURL) in allFilesMap {
                if textExtensions.contains(newURL.pathExtension.lowercased()) {
                    do {
                        try self.updateReferences(in: newURL, allFilesMap: allFilesMap)
                    } catch {
                        print("Error updating refs in \(newURL.lastPathComponent): \(error)")
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.isProcessing = false
                if errorCount == 0 { self.statusMessage = "Changes executed"; self.addedRules.removeAll(); self.pendingContentEdits.removeAll(); self.refreshTree() }
                else { self.statusMessage = "Executed with \(errorCount) errors."; self.refreshTree() }
            }
        }
    }
    
    // Logic to update references (Copied and adapted from early version)
    private func updateReferences(in fileURL: URL, allFilesMap: [URL: URL]) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
        var content = try String(contentsOf: fileURL, encoding: .utf8)
        let pattern = #"(src|href|url)=["']?([^"'>\s]+)["']?"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let matches = regex.matches(in: content, options: [], range: NSRange(content.startIndex..., in: content))
        var changed = false
        
        for match in matches.reversed() {
            if let pathRange = Range(match.range(at: 2), in: content) {
                let foundPath = String(content[pathRange])
                if foundPath.contains("http") || foundPath.hasPrefix("#") || foundPath.hasPrefix("mailto:") { continue }
                
                // Find original location of THIS file (fileURL) to resolve relative paths
                // We look for key where value == fileURL
                guard let originalFileLocation = allFilesMap.first(where: { $0.value == fileURL })?.key else { continue }
                
                let originalDir = originalFileLocation.deletingLastPathComponent()
                let targetAbsOriginal = originalDir.appendingPathComponent(foundPath).standardizedFileURL
                
                // Check if the target exists in our map (meaning it's a file in our project)
                // We check if we have a known destination for this target
                if let targetNewLocation = allFilesMap[targetAbsOriginal] {
                    let newDir = fileURL.deletingLastPathComponent()
                    let newRelPath = calculateRelPath(from: newDir, to: targetNewLocation)
                    
                    if foundPath != newRelPath {
                        content.replaceSubrange(pathRange, with: newRelPath)
                        changed = true
                    }
                }
            }
        }
        
        if changed { try content.write(to: fileURL, atomically: true, encoding: .utf8) }
    }
    
    private func calculateRelPath(from base: URL, to target: URL) -> String {
        let basePath = base.path.split(separator: "/")
        let targetPath = target.path.split(separator: "/")
        var common = 0
        while common < basePath.count && common < targetPath.count && basePath[common] == targetPath[common] { common += 1 }
        let up = Array(repeating: "..", count: basePath.count - common)
        let down = targetPath[common...].map { String($0) }
        return (up + down).joined(separator: "/")
    }
    
    func revertChanges() { refreshTree(); addedRules.removeAll(); pendingContentEdits.removeAll() }
    
    // MARK: - Helpers (Condensed)
    
    private func buildGlobalFileMap(nodes: [FileNode]) -> [URL: URL] {
        var map: [URL: URL] = [:]
        for node in nodes {
            map[node.url] = node.destinationURL
            if let children = node.children {
                let childMap = buildGlobalFileMap(nodes: children)
                map.merge(childMap) { (_, new) in new }
            }
        }
        return map
    }
    
    private func collectNodesForEditor(scope: EditorScope, selectedIDs: Set<UUID>, nodes: [FileNode]) -> [FileNode] {
        var results: [FileNode] = []
        for node in nodes {
            if node.isDirectory {
                if let children = node.children { results.append(contentsOf: collectNodesForEditor(scope: scope, selectedIDs: selectedIDs, nodes: children)) }
            } else {
                if scope == .allFiles { results.append(node) }
                else if scope == .selectedFiles && selectedIDs.contains(node.id) { results.append(node) }
            }
        }
        return results
    }
    private func restoreContentEdits() {
        updateTree(nodes: &fileTree) { node in if self.pendingContentEdits[node.id] != nil { node.isContentModified = true } }
        recalculateStagedChanges()
    }
    private func recalculateStagedChanges() {
        var changes = collectChangedNodes(nodes: self.fileTree)
        let fileManager = FileManager.default
        var implicitFolders: Set<URL> = []
        for change in changes {
            let destFolder = change.destinationURL.deletingLastPathComponent()
            var isDir: ObjCBool = false
            let existsOnDisk = fileManager.fileExists(atPath: destFolder.path, isDirectory: &isDir)
            if !existsOnDisk {
                let alreadyVirtual = changes.contains { $0.isVirtual && $0.url == destFolder }
                if !alreadyVirtual { implicitFolders.insert(destFolder) }
            }
        }
        for folderURL in implicitFolders {
            let node = FileNode(url: folderURL, name: folderURL.lastPathComponent, isDirectory: true, children: nil, destinationURL: folderURL, isVirtual: false, isManuallyMoved: false, isImplicitRuleFolder: true)
            changes.insert(node, at: 0)
        }
        DispatchQueue.main.async { self.stagedChanges = changes; self.objectWillChange.send() }
    }
    private func collectChangedNodes(nodes: [FileNode]) -> [FileNode] {
        var staged: [FileNode] = []
        for node in nodes { if node.isMoved || node.isVirtual || node.isContentModified { staged.append(node) }; if let children = node.children { staged.append(contentsOf: collectChangedNodes(nodes: children)) } }
        return staged
    }
    private func buildTree(from url: URL) -> [FileNode] {
        var nodes: [FileNode] = []
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            for fileURL in fileURLs {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
                let children: [FileNode]? = isDir.boolValue ? buildTree(from: fileURL) : nil
                nodes.append(FileNode(url: fileURL, name: fileURL.lastPathComponent, isDirectory: isDir.boolValue, children: children))
            }
        } catch {}
        return nodes.sorted { ($0.isDirectory && !$1.isDirectory) || ($0.name < $1.name) }
    }
    private func getAllFolderNames(nodes: [FileNode]) -> [String] {
        var names: [String] = []
        for node in nodes { if node.isDirectory { names.append(node.name); if let children = node.children { names.append(contentsOf: getAllFolderNames(nodes: children)) } } }
        return Array(Set(names)).sorted()
    }
    private func updateTree(nodes: inout [FileNode], targetID: UUID, transform: (inout FileNode) -> Void) {
        for i in 0..<nodes.count {
            if nodes[i].id == targetID { transform(&nodes[i]); return }
            if nodes[i].isDirectory, nodes[i].children != nil { updateTree(nodes: &nodes[i].children!, targetID: targetID, transform: transform) }
        }
    }
    private func updateTree(nodes: inout [FileNode], transform: (inout FileNode) -> Void) {
        for i in 0..<nodes.count {
            transform(&nodes[i])
            if nodes[i].isDirectory, nodes[i].children != nil { updateTree(nodes: &nodes[i].children!, transform: transform) }
        }
    }
    private func resetAutoDestinations(nodes: inout [FileNode]) {
        for i in 0..<nodes.count {
            if !nodes[i].isManuallyMoved && !nodes[i].isVirtual { nodes[i].destinationURL = nodes[i].url }
            if nodes[i].children != nil { resetAutoDestinations(nodes: &nodes[i].children!) }
        }
    }
    private func findNode(id: UUID, nodes: [FileNode]) -> FileNode? {
        for node in nodes { if node.id == id { return node }; if let children = node.children, let found = findNode(id: id, nodes: children) { return found } }
        return nil
    }
    func findParentID(for childID: UUID, nodes: [FileNode]) -> UUID? {
        for node in nodes { if let children = node.children { if children.contains(where: { $0.id == childID }) { return node.id }; if let found = findParentID(for: childID, nodes: children) { return found } } }
        return nil
    }
    private func findURL(for id: UUID?, in nodes: [FileNode]) -> URL? {
        guard let id = id else { return nil }
        for node in nodes { if node.id == id { return node.destinationURL }; if let children = node.children, let found = findURL(for: id, in: children) { return found } }
        return nil
    }
    private func findDestinations(for ids: [UUID], in nodes: [FileNode]) -> [UUID: URL] {
        var map: [UUID: URL] = [:]
        for node in nodes { if ids.contains(node.id) { map[node.id] = node.destinationURL }; if let children = node.children { map.merge(findDestinations(for: ids, in: children)) { (_, new) in new } } }
        return map
    }
    private func restoreDestinations(originalDestinations: [UUID: URL]) {
        updateTree(nodes: &fileTree) { node in if let original = originalDestinations[node.id] { node.destinationURL = original } }
        recalculateStagedChanges()
    }
}

// MARK: - UI Extension
extension String {
    func ranges(of substring: String, options: CompareOptions = [], locale: Locale? = nil) -> [Range<Index>] {
        var ranges: [Range<Index>] = []
        var start = startIndex
        while let range = self.range(of: substring, options: options, range: start..<endIndex, locale: locale) {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }
}

// MARK: - UI Components

struct DarkPanelBox<Content: View>: View {
    let title: String
    let content: Content
    init(title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.gray)
                .padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
            Divider()
            content.padding(10)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct FileRow: View {
    let node: FileNode
    @ObservedObject var viewModel: OrganizerViewModel
    @Environment(\.undoManager) var undoManager
    @State private var isRenaming = false
    @State private var renameText = ""
    
    var body: some View {
        HStack {
            Image(systemName: node.isDirectory ? (node.isVirtual ? "folder.badge.plus" : "folder.fill") : "doc")
                .foregroundColor(node.isDirectory ? .blue : .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).foregroundColor(.primary)
                if node.isMoved {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                        Text(node.destinationURL.deletingLastPathComponent().lastPathComponent + "/" + node.name)
                    }.font(.caption).foregroundColor(.green)
                }
                if node.isContentModified {
                    Text("Content Edited").font(.caption2).foregroundColor(.orange).padding(.horizontal, 4).background(Color.orange.opacity(0.2)).cornerRadius(2)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Use for Rule") { viewModel.populateRuleFromSelection(clickedID: node.id) }
            Divider()
            Button("Open File") { _ = NSWorkspace.shared.open(node.url) }
            Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Rename") { renameText = node.name; isRenaming = true }
            Divider()
            Button("New Folder") {
                let parentID = node.isDirectory ? node.id : viewModel.findParentID(for: node.id, nodes: viewModel.fileTree)
                viewModel.createVirtualFolder(name: "New Folder", parentID: parentID, undoManager: undoManager)
            }
        }
        .alert("Rename File", isPresented: $isRenaming) {
            TextField("New Name", text: $renameText)
            Button("Rename") { viewModel.renameNode(node.id, to: renameText, undoManager: undoManager) }
            Button("Cancel", role: .cancel) { }
        }
        .onDrag {
            if let event = NSApp.currentEvent, event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
                return NSItemProvider()
            }
            let idsToDrag = viewModel.selectedIDs.contains(node.id) ? Array(viewModel.selectedIDs) : [node.id]
            let stringData = idsToDrag.map { $0.uuidString }.joined(separator: ",")
            let provider = NSItemProvider(object: stringData as NSString)
            if idsToDrag.count > 1 { provider.suggestedName = "\(idsToDrag.count) Items" }
            else { provider.suggestedName = node.name }
            return provider
        }
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
            guard node.isDirectory else { return false }
            if let item = providers.first {
                item.loadObject(ofClass: NSString.self) { (string, error) in
                    if let stringData = string as? String {
                        let uuidList = stringData.components(separatedBy: ",").compactMap { UUID(uuidString: $0) }
                        if !uuidList.isEmpty { DispatchQueue.main.async { viewModel.moveItems(ids: uuidList, toFolder: node, undoManager: undoManager) } }
                    }
                }
                return true
            }
            return false
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject var viewModel = OrganizerViewModel()
    @Environment(\.undoManager) var undoManager
    
    var body: some View {
        VStack(spacing: 0) {
            
            // 1. TOP BAR
            HStack(spacing: 12) {
                Picker("Mode", selection: $viewModel.appMode) {
                    ForEach(AppMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(SegmentedPickerStyle()).frame(width: 250)
                Spacer()
                Button(action: { viewModel.revertChanges() }) { Label("Revert All", systemImage: "arrow.counterclockwise") }.controlSize(.small)
                Button(action: { viewModel.createNewFolderFromSelection(undoManager: undoManager) }) { Label("New Folder", systemImage: "folder.badge.plus") }.controlSize(.small).disabled(viewModel.rootURL == nil)
            }
            .padding(10).background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // 2. MAIN SPLIT VIEW
            HSplitView {
                
                // LEFT SIDEBAR
                VStack(spacing: 0) {
                    if let root = viewModel.rootURL {
                        HStack {
                            Text(root.path).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }.padding(8).background(Color(NSColor.controlBackgroundColor))
                        Divider()
                    }
                    
                    List(viewModel.fileTree, children: \.children, selection: Binding(
                        get: { viewModel.selectedIDs },
                        set: { val in DispatchQueue.main.async { viewModel.selectedIDs = val } }
                    )) { node in
                        FileRow(node: node, viewModel: viewModel)
                    }
                    .listStyle(SidebarListStyle())
                    .onExitCommand { viewModel.clearSelection() }
                }
                .frame(minWidth: 250)
                
                // RIGHT PANEL
                VStack(spacing: 16) {
                    if viewModel.appMode == .organize {
                        DarkPanelBox(title: "Create Organization Rule") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Select Type:").font(.caption).foregroundColor(.secondary)
                                    Picker("", selection: $viewModel.newRuleType) { ForEach(RuleType.allCases) { type in Text(type.rawValue).tag(type) } }.labelsHidden().frame(width: 120)
                                }
                                HStack(spacing: 8) {
                                    TextField(viewModel.newRuleType == .extensionMatch ? "Ext (e.g. jpg)" : "Name text", text: $viewModel.newRuleCriteria).textFieldStyle(RoundedBorderTextFieldStyle()).onSubmit { viewModel.addRule(undoManager: undoManager) }
                                    Image(systemName: "arrow.right").foregroundColor(.gray)
                                    HStack(spacing: 0) {
                                        TextField("Folder (e.g. Assets)", text: $viewModel.newRuleFolder).textFieldStyle(RoundedBorderTextFieldStyle()).onSubmit { viewModel.addRule(undoManager: undoManager) }
                                        Menu { ForEach(viewModel.availableFolders, id: \.self) { folderName in Button(folderName) { viewModel.newRuleFolder = folderName } } } label: { Image(systemName: "chevron.down").font(.caption).foregroundColor(.secondary).padding(.leading, 4) }.menuStyle(.borderlessButton).frame(width: 20)
                                    }
                                }
                                Button("Add Rule") { viewModel.addRule(undoManager: undoManager) }.controlSize(.small)
                            }
                        }.frame(height: 130)
                        
                        DarkPanelBox(title: "Rules") {
                            if viewModel.addedRules.isEmpty { Text("No rules added yet.").font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                            else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(viewModel.addedRules) { rule in
                                            HStack {
                                                Text(rule.criteria).font(.system(.caption, design: .monospaced)).padding(4).background(Color.blue.opacity(0.3)).cornerRadius(4)
                                                Image(systemName: "arrow.right").font(.caption2).foregroundColor(.gray)
                                                Text(rule.targetFolder).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                                                Spacer()
                                            }
                                            Divider().background(Color.white.opacity(0.1))
                                        }
                                    }
                                }
                            }
                        }.frame(minHeight: 100)
                        
                    } else if viewModel.appMode == .editor {
                        DarkPanelBox(title: "Find Configuration") {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Find:").font(.caption).foregroundColor(.secondary)
                                    TextEditor(text: $viewModel.editorFindText).font(.system(.body, design: .monospaced)).frame(minHeight: 40).background(Color.black.opacity(0.2)).cornerRadius(4).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1)))
                                }
                                HStack(spacing: 16) {
                                    Toggle("Wildcard (*)", isOn: $viewModel.editorIsWildcard).toggleStyle(SwitchToggleStyle(tint: .blue)).controlSize(.small).disabled(viewModel.editorIsRegex)
                                    Toggle("Regex", isOn: $viewModel.editorIsRegex).toggleStyle(SwitchToggleStyle(tint: .blue)).controlSize(.small).disabled(viewModel.editorIsWildcard)
                                    Toggle("Case Sensitive", isOn: $viewModel.editorCaseSensitive).toggleStyle(SwitchToggleStyle(tint: .blue)).controlSize(.small)
                                }
                                Divider().background(Color.white.opacity(0.1))
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { Text("Scope:").font(.caption).foregroundColor(.secondary); Picker("", selection: $viewModel.editorScope) { ForEach(EditorScope.allCases, id: \.self) { scope in Text(scope.rawValue).tag(scope) } }.labelsHidden().frame(width: 140); Spacer() }
                                    HStack { Text("Extensions:").font(.caption).foregroundColor(.secondary); TextField("e.g. html, css", text: $viewModel.editorTargetExtensions).textFieldStyle(RoundedBorderTextFieldStyle()) }
                                }
                            }
                        }.frame(height: 250)
                        
                        DarkPanelBox(title: "Replace") {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Replace with:").font(.caption).foregroundColor(.secondary)
                                    TextEditor(text: $viewModel.editorReplaceText).font(.system(.body, design: .monospaced)).frame(minHeight: 40).background(Color.black.opacity(0.2)).cornerRadius(4).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1)))
                                }
                                HStack { Spacer(); if viewModel.isProcessing { ProgressView().scaleEffect(0.5) }; Button("Preview & Stage Changes") { viewModel.stageContentEdit() } }
                            }
                        }.frame(height: 120)
                        
                    } else if viewModel.appMode == .search {
                        DarkPanelBox(title: "Search Configuration") {
                            VStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Search Text:").font(.caption).foregroundColor(.secondary)
                                    TextEditor(text: $viewModel.searchText).font(.system(.body, design: .monospaced)).frame(minHeight: 40, maxHeight: 80).background(Color.black.opacity(0.2)).cornerRadius(4).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1)))
                                }
                                HStack(spacing: 16) {
                                    Toggle("Wildcard (*)", isOn: $viewModel.searchIsWildcard).toggleStyle(SwitchToggleStyle(tint: .blue)).controlSize(.small).disabled(viewModel.searchIsRegex)
                                    Toggle("Regex", isOn: $viewModel.searchIsRegex).toggleStyle(SwitchToggleStyle(tint: .blue)).controlSize(.small).disabled(viewModel.searchIsWildcard)
                                    Toggle("Case Sensitive", isOn: $viewModel.searchCaseSensitive).toggleStyle(SwitchToggleStyle(tint: .blue)).controlSize(.small)
                                    Spacer()
                                    if !viewModel.searchText.isEmpty { Button("Clear") { viewModel.searchText = "" }.buttonStyle(.bordered).controlSize(.small) }
                                    Button("Search") { viewModel.performSearch() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                                }
                            }
                        }.frame(height: 160)
                        
                        DarkPanelBox(title: "Search Results") {
                            if viewModel.searchResults.isEmpty {
                                Spacer()
                                Text(viewModel.statusMessage).font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
                                Spacer()
                            }
                            else {
                                List(viewModel.searchResults) { result in
                                    Button(action: { NSWorkspace.shared.open(result.url) }) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack { Text(result.fileName).bold(); Spacer(); Text("Line \(result.lineNumber)").font(.caption).foregroundColor(.secondary) }
                                            Text(result.lineContent).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Open File") { NSWorkspace.shared.open(result.url) }
                                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                                        Button("Copy Code") { let p = NSPasteboard.general; p.clearContents(); p.setString(result.lineContent, forType: .string) }
                                    }
                                }.listStyle(PlainListStyle())
                            }
                        }
                    }
                    
                    if viewModel.appMode != .search {
                        DarkPanelBox(title: "Actions") {
                            if viewModel.stagedChanges.isEmpty { Text("No pending actions.").font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                            else {
                                List(selection: $viewModel.actionSelectedIDs) {
                                    ForEach(viewModel.stagedChanges) { node in
                                        HStack {
                                            HStack(spacing: 6) { Image(systemName: node.isDirectory ? (node.isVirtual || node.isImplicitRuleFolder ? "folder.badge.plus" : "folder.fill") : "doc").foregroundColor(node.isDirectory ? .blue : .secondary); Text(node.name).lineLimit(1).truncationMode(.middle) }
                                            Spacer()
                                            if node.isContentModified { Image(systemName: "pencil").font(.caption2).foregroundColor(.orange) } else { Image(systemName: "arrow.right").font(.caption2).foregroundColor(.gray) }
                                            Spacer()
                                            if node.isContentModified { Text("Modify Content").foregroundColor(.orange).font(.caption) } else if node.isVirtual || node.isImplicitRuleFolder { Text("Create Folder").foregroundColor(.green).font(.caption) } else { Text(node.destinationURL.deletingLastPathComponent().lastPathComponent).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle) }
                                        }
                                        .tag(node.id)
                                        .contextMenu {
                                            if viewModel.actionSelectedIDs.count <= 1 { Button("Create Rule from this") { viewModel.actionSelectedIDs = [node.id]; viewModel.populateRuleFromAction() }; Divider() }
                                            Button("Delete Action") { if viewModel.actionSelectedIDs.isEmpty { viewModel.actionSelectedIDs = [node.id] }; viewModel.revertSelectedActions(undoManager: undoManager) }
                                        }
                                    }
                                }.listStyle(PlainListStyle())
                            }
                        }
                    }
                }.padding().frame(minWidth: 400)
            }
            
            Divider()
            
            // 3. BOTTOM BAR
            HStack {
                Button(action: { viewModel.selectFolder() }) { Label("Open", systemImage: "folder") }.buttonStyle(.bordered).tint(.gray)
                Button(action: { if let url = viewModel.rootURL { NSWorkspace.shared.open(url) } }) { Label("Open in Finder", systemImage: "macwindow") }.buttonStyle(.bordered).tint(.gray).disabled(viewModel.rootURL == nil)
                Spacer()
                Text(viewModel.statusMessage).font(.caption).foregroundColor(.gray)
                Spacer()
                Button(action: { viewModel.execute() }) { Text("Execute Changes").bold() }.buttonStyle(.borderedProminent).tint(.blue).disabled(viewModel.stagedChanges.isEmpty)
            }
            .padding(12).background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
    }
}
