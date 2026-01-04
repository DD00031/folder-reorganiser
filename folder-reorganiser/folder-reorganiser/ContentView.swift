import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Enums & Models

enum RuleType: String, CaseIterable, Identifiable {
    case extensionMatch = "Extension"
    case nameContains = "Name Contains"
    var id: String { self.rawValue }
}

struct OrganizationRule: Identifiable, Hashable {
    let id = UUID()
    let type: RuleType
    let criteria: String
    let targetFolder: String
}

struct FileNode: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var name: String
    let isDirectory: Bool
    var children: [FileNode]?
    
    var destinationURL: URL
    var isVirtual: Bool = false
    
    // Protects manual drags from being overwritten by rules
    var isManuallyMoved: Bool = false
    // Helper to identify folders implicitly created by rules for the UI
    var isImplicitRuleFolder: Bool = false
    
    var isMoved: Bool {
        return url != destinationURL
    }
    
    init(url: URL, name: String, isDirectory: Bool, children: [FileNode]? = nil, destinationURL: URL? = nil, isVirtual: Bool = false, isManuallyMoved: Bool = false, isImplicitRuleFolder: Bool = false) {
        self.id = UUID()
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.destinationURL = destinationURL ?? url
        self.isVirtual = isVirtual
        self.isManuallyMoved = isManuallyMoved
        self.isImplicitRuleFolder = isImplicitRuleFolder
    }
}

// MARK: - View Model

class OrganizerViewModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var rootPathString: String = ""
    @Published var fileTree: [FileNode] = []
    
    // Observed by the View for the Actions Panel
    @Published var stagedChanges: [FileNode] = []
    
    @Published var statusMessage: String = "Ready."
    @Published var isProcessing = false
    @Published var selectedIDs: Set<UUID> = []
    
    // Rule Inputs
    @Published var addedRules: [OrganizationRule] = []
    @Published var newRuleType: RuleType = .extensionMatch
    @Published var newRuleCriteria: String = ""
    @Published var newRuleFolder: String = ""
    
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
        // Keep "Changes executed" message if we just finished, otherwise show scanning
        if self.statusMessage != "Changes executed" {
            self.statusMessage = "Scanning..."
        }
        
        DispatchQueue.global(qos: .userInteractive).async {
            let tree = self.buildTree(from: root)
            DispatchQueue.main.async {
                self.fileTree = tree
                self.applyRules()
                if self.statusMessage == "Scanning..." {
                    self.statusMessage = "Ready."
                }
            }
        }
    }
    
    func forceRefreshActions() {
        self.recalculateStagedChanges()
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
            }
        }
        
        addedRules.append(rule)
        applyRules()
        
        newRuleCriteria = ""
        newRuleFolder = ""
    }
    
    func applyRules() {
        guard let root = rootURL else { return }
        
        resetAutoDestinations(nodes: &fileTree)
        
        updateTree(nodes: &fileTree) { node in
            if node.isDirectory || node.isManuallyMoved { return }
            
            for rule in addedRules {
                var matches = false
                
                if rule.type == .extensionMatch {
                    let rawExtensions = rule.criteria.components(separatedBy: .whitespacesAndNewlines)
                        .flatMap { $0.components(separatedBy: ",") }
                    
                    let targetExtensions = rawExtensions.compactMap { ext -> String? in
                        let clean = ext.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces).lowercased()
                        return clean.isEmpty ? nil : clean
                    }
                    
                    let nodeExt = node.url.pathExtension.lowercased()
                    matches = targetExtensions.contains(nodeExt)
                    
                } else if rule.type == .nameContains {
                    matches = node.name.localizedCaseInsensitiveContains(rule.criteria)
                }
                
                if matches {
                    let targetDir = root.appendingPathComponent(rule.targetFolder)
                    let newDest = targetDir.appendingPathComponent(node.name)
                    node.destinationURL = newDest
                    return
                }
            }
        }
        recalculateStagedChanges()
    }
    
    // MARK: - Folder Creation
    
    func createNewFolderFromSelection(undoManager: UndoManager?) {
        let name = "New Folder"
        var targetParentID: UUID? = nil
        
        if selectedIDs.count == 1, let selectedID = selectedIDs.first {
            if let node = findNode(id: selectedID, nodes: fileTree) {
                if node.isDirectory {
                    targetParentID = node.id
                } else {
                    targetParentID = findParentID(for: node.id, nodes: fileTree)
                }
            }
        }
        createVirtualFolder(name: name, parentID: targetParentID, undoManager: undoManager)
    }
    
    func createVirtualFolder(name: String, parentID: UUID?, undoManager: UndoManager?) {
        guard let root = rootURL else { return }
        
        let parentURL = findURL(for: parentID, in: fileTree) ?? root
        let virtualURL = parentURL.appendingPathComponent(name)
        
        let newNode = FileNode(url: virtualURL, name: name, isDirectory: true, children: [], destinationURL: virtualURL, isVirtual: true)
        
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.refreshTree()
        }
        
        if let pid = parentID {
            updateTree(nodes: &fileTree, targetID: pid) { parent in
                if parent.children == nil { parent.children = [] }
                parent.children?.append(newNode)
            }
        } else {
            fileTree.append(newNode)
        }
        recalculateStagedChanges()
    }
    
    // MARK: - Drag & Drop / Rename
    
    func moveItems(ids: [UUID], toFolder node: FileNode, undoManager: UndoManager?) {
        guard node.isDirectory else { return }
        let currentDestinations = findDestinations(for: ids, in: fileTree)
        
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.restoreDestinations(originalDestinations: currentDestinations)
        }
        
        for id in ids {
            updateTree(nodes: &fileTree, targetID: id) { item in
                if node.destinationURL.path.contains(item.url.path) { return }
                
                let newDest = node.destinationURL.appendingPathComponent(item.name)
                item.destinationURL = newDest
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
            }
            node.name = newName
            let parentPath = node.destinationURL.deletingLastPathComponent()
            node.destinationURL = parentPath.appendingPathComponent(newName)
        }
        recalculateStagedChanges()
    }
    
    // MARK: - EXECUTION
    
    func execute() {
        guard let root = rootURL else { return }
        isProcessing = true
        statusMessage = "Executing..."
        
        let fileManager = FileManager.default
        let changesToProcess = self.stagedChanges
        
        DispatchQueue.global(qos: .userInitiated).async {
            var errorCount = 0
            
            // 1. Create Directories
            let parentFolders = Set(changesToProcess.map { $0.destinationURL.deletingLastPathComponent() })
            for folder in parentFolders {
                do {
                    if !fileManager.fileExists(atPath: folder.path) {
                        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
                    }
                } catch {
                    print("Error creating folder \(folder.lastPathComponent): \(error)")
                    errorCount += 1
                }
            }
            
            // 2. Move Files
            for node in changesToProcess {
                do {
                    if node.isDirectory {
                        if node.isVirtual || node.isImplicitRuleFolder {
                             if !fileManager.fileExists(atPath: node.destinationURL.path) {
                                try fileManager.createDirectory(at: node.destinationURL, withIntermediateDirectories: true, attributes: nil)
                            }
                        } else if node.isMoved {
                             try fileManager.moveItem(at: node.url, to: node.destinationURL)
                        }
                    } else {
                        if fileManager.fileExists(atPath: node.url.path) {
                            try fileManager.moveItem(at: node.url, to: node.destinationURL)
                        }
                    }
                } catch {
                    print("Error moving \(node.name): \(error)")
                    errorCount += 1
                }
            }
            
            DispatchQueue.main.async {
                self.isProcessing = false
                if errorCount == 0 {
                    self.statusMessage = "Changes executed"
                    self.addedRules.removeAll() // <--- CLEARS RULES ON SUCCESS
                    self.refreshTree()
                } else {
                    self.statusMessage = "Executed with \(errorCount) errors."
                    self.refreshTree()
                }
            }
        }
    }
    
    func revertChanges() {
        refreshTree()
        addedRules.removeAll()
    }

    // MARK: - Helpers
    
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
                if !alreadyVirtual {
                    implicitFolders.insert(destFolder)
                }
            }
        }
        
        for folderURL in implicitFolders {
            let node = FileNode(
                url: folderURL,
                name: folderURL.lastPathComponent,
                isDirectory: true,
                children: nil,
                destinationURL: folderURL,
                isVirtual: false,
                isManuallyMoved: false,
                isImplicitRuleFolder: true
            )
            changes.insert(node, at: 0)
        }
        
        DispatchQueue.main.async {
            self.stagedChanges = changes
            self.objectWillChange.send()
        }
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
        for node in nodes {
            if node.isDirectory {
                names.append(node.name)
                if let children = node.children {
                    names.append(contentsOf: getAllFolderNames(nodes: children))
                }
            }
        }
        return Array(Set(names)).sorted()
    }
    
    private func collectChangedNodes(nodes: [FileNode]) -> [FileNode] {
        var staged: [FileNode] = []
        for node in nodes {
            if node.isMoved || node.isVirtual { staged.append(node) }
            if let children = node.children { staged.append(contentsOf: collectChangedNodes(nodes: children)) }
        }
        return staged
    }
    
    private func updateTree(nodes: inout [FileNode], targetID: UUID, transform: (inout FileNode) -> Void) {
        for i in 0..<nodes.count {
            if nodes[i].id == targetID { transform(&nodes[i]); return }
            if nodes[i].isDirectory, nodes[i].children != nil {
                updateTree(nodes: &nodes[i].children!, targetID: targetID, transform: transform)
            }
        }
    }
    
    private func updateTree(nodes: inout [FileNode], transform: (inout FileNode) -> Void) {
        for i in 0..<nodes.count {
            transform(&nodes[i])
            if nodes[i].isDirectory, nodes[i].children != nil {
                updateTree(nodes: &nodes[i].children!, transform: transform)
            }
        }
    }
    
    private func resetAutoDestinations(nodes: inout [FileNode]) {
        for i in 0..<nodes.count {
            if !nodes[i].isManuallyMoved && !nodes[i].isVirtual {
                nodes[i].destinationURL = nodes[i].url
            }
            if nodes[i].children != nil { resetAutoDestinations(nodes: &nodes[i].children!) }
        }
    }
    
    private func findNode(id: UUID, nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let found = findNode(id: id, nodes: children) { return found }
        }
        return nil
    }
    
    func findParentID(for childID: UUID, nodes: [FileNode]) -> UUID? {
        for node in nodes {
            if let children = node.children {
                if children.contains(where: { $0.id == childID }) { return node.id }
                if let found = findParentID(for: childID, nodes: children) { return found }
            }
        }
        return nil
    }
    
    private func findURL(for id: UUID?, in nodes: [FileNode]) -> URL? {
        guard let id = id else { return nil }
        for node in nodes {
            if node.id == id { return node.destinationURL }
            if let children = node.children, let found = findURL(for: id, in: children) { return found }
        }
        return nil
    }
    
    private func findDestinations(for ids: [UUID], in nodes: [FileNode]) -> [UUID: URL] {
        var map: [UUID: URL] = [:]
        for node in nodes {
            if ids.contains(node.id) { map[node.id] = node.destinationURL }
            if let children = node.children { map.merge(findDestinations(for: ids, in: children)) { (_, new) in new } }
        }
        return map
    }
    
    private func restoreDestinations(originalDestinations: [UUID: URL]) {
        updateTree(nodes: &fileTree) { node in
            if let original = originalDestinations[node.id] {
                node.destinationURL = original
            }
        }
        recalculateStagedChanges()
    }
}

// MARK: - UI Components

struct DarkPanelBox<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.gray)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
            
            Divider()
            content.padding(10)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

struct FileRow: View {
    let node: FileNode
    @ObservedObject var viewModel: OrganizerViewModel
    @Environment(\.undoManager) var undoManager
    
    @State private var isTargeted = false
    @State private var isRenaming = false
    @State private var renameText = ""
    
    var body: some View {
        HStack {
            Image(systemName: node.isDirectory ? (node.isVirtual ? "folder.badge.plus" : "folder.fill") : "doc")
                .foregroundColor(node.isDirectory ? .blue : .gray)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .foregroundColor(.primary)
                
                if node.isMoved {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                        Text(node.destinationURL.deletingLastPathComponent().lastPathComponent + "/" + node.name)
                    }
                    .font(.caption)
                    .foregroundColor(.green)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .background(isTargeted ? Color.blue.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        
        .contextMenu {
            Button("Open in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            Button("Rename") {
                renameText = node.name
                isRenaming = true
            }
            Divider()
            Button("New Folder") {
                if node.isDirectory {
                    viewModel.createVirtualFolder(name: "New Folder", parentID: node.id, undoManager: undoManager)
                } else {
                    let parentID = viewModel.findParentID(for: node.id, nodes: viewModel.fileTree)
                    viewModel.createVirtualFolder(name: "New Folder", parentID: parentID, undoManager: undoManager)
                }
            }
        }
        .alert("Rename File", isPresented: $isRenaming) {
            TextField("New Name", text: $renameText)
            Button("Rename") {
                viewModel.renameNode(node.id, to: renameText, undoManager: undoManager)
            }
            Button("Cancel", role: .cancel) { }
        }
        .onDrag {
            let idsToDrag: [UUID]
            if viewModel.selectedIDs.contains(node.id) {
                idsToDrag = Array(viewModel.selectedIDs)
            } else {
                idsToDrag = [node.id]
            }
            let stringData = idsToDrag.map { $0.uuidString }.joined(separator: ",")
            return NSItemProvider(object: stringData as NSString)
        }
        .onDrop(of: [UTType.plainText], isTargeted: $isTargeted) { providers in
            guard node.isDirectory else { return false }
            
            if let item = providers.first {
                item.loadObject(ofClass: NSString.self) { (string, error) in
                    if let stringData = string as? String {
                        let uuidStrings = stringData.components(separatedBy: ",")
                        let uuidList = uuidStrings.compactMap { UUID(uuidString: $0) }
                        
                        if !uuidList.isEmpty {
                            DispatchQueue.main.async {
                                viewModel.moveItems(ids: uuidList, toFolder: node, undoManager: undoManager)
                            }
                        }
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected: \(viewModel.rootPathString.isEmpty ? "None" : viewModel.rootPathString)")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }
                
                Button("Force Refresh") {
                    viewModel.forceRefreshActions()
                }
                .keyboardShortcut("r", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                
                Spacer()
                
                Button(action: { viewModel.revertChanges() }) {
                    Label("Revert All", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                
                Button(action: { viewModel.createNewFolderFromSelection(undoManager: undoManager) }) {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)
                .disabled(viewModel.rootURL == nil)
            }
            .padding(10)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            HSplitView {
                // 2. LEFT SIDEBAR
                List(viewModel.fileTree, children: \.children, selection: $viewModel.selectedIDs) { node in
                    FileRow(node: node, viewModel: viewModel)
                }
                .listStyle(SidebarListStyle())
                .frame(minWidth: 250)
                
                // 3. RIGHT PANEL
                VStack(spacing: 16) {
                    
                    // A. Create Rule
                    DarkPanelBox(title: "Create Organization Rule") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Select Type:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Picker("", selection: $viewModel.newRuleType) {
                                    ForEach(RuleType.allCases) { type in
                                        Text(type.rawValue).tag(type)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 120)
                            }
                            
                            HStack(spacing: 8) {
                                TextField(viewModel.newRuleType == .extensionMatch ? "Ext (e.g. jpg)" : "Name text", text: $viewModel.newRuleCriteria)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .onSubmit { viewModel.addRule(undoManager: undoManager) }
                                
                                Image(systemName: "arrow.right")
                                    .foregroundColor(.gray)
                                
                                HStack(spacing: 0) {
                                    TextField("Folder (e.g. Assets)", text: $viewModel.newRuleFolder)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .onSubmit { viewModel.addRule(undoManager: undoManager) }
                                    
                                    Menu {
                                        if viewModel.availableFolders.isEmpty {
                                            Text("No folders found").font(.caption)
                                        } else {
                                            ForEach(viewModel.availableFolders, id: \.self) { folderName in
                                                Button(folderName) {
                                                    viewModel.newRuleFolder = folderName
                                                }
                                            }
                                        }
                                    } label: {
                                    }
                                    .menuStyle(.borderlessButton)
                                    .frame(width: 20)
                                }
                            }
                            
                            Button("Add Rule") {
                                viewModel.addRule(undoManager: undoManager)
                            }
                            .controlSize(.small)
                        }
                    }
                    .frame(height: 130)
                    
                    // B. Active Rules
                    DarkPanelBox(title: "Rules") {
                        if viewModel.addedRules.isEmpty {
                            Text("No rules added yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(viewModel.addedRules) { rule in
                                        HStack {
                                            let displayText: String = {
                                                if rule.type == .extensionMatch {
                                                    let exts = rule.criteria.components(separatedBy: .whitespacesAndNewlines)
                                                        .flatMap { $0.components(separatedBy: ",") }
                                                        .map { $0.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces) }
                                                        .filter { !$0.isEmpty }
                                                    return exts.map { "*.\($0)" }.joined(separator: ", ")
                                                } else {
                                                    return "\"\(rule.criteria)\""
                                                }
                                            }()
                                            
                                            Text(displayText)
                                                .font(.system(.caption, design: .monospaced))
                                                .padding(4)
                                                .background(Color.blue.opacity(0.3))
                                                .cornerRadius(4)
                                            
                                            Image(systemName: "arrow.right")
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                            
                                            Text(rule.targetFolder)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundColor(.secondary)
                                            
                                            Spacer()
                                        }
                                        Divider().background(Color.white.opacity(0.1))
                                    }
                                }
                            }
                        }
                    }
                    .frame(minHeight: 100)
                    
                    // C. Actions
                    DarkPanelBox(title: "Actions") {
                        if viewModel.stagedChanges.isEmpty {
                            Text("No pending actions.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            ScrollView {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                    ForEach(viewModel.stagedChanges) { node in
                                        GridRow {
                                            // 1. Source
                                            HStack(spacing: 6) {
                                                Image(systemName: node.isDirectory ? (node.isVirtual || node.isImplicitRuleFolder ? "folder.badge.plus" : "folder.fill") : "doc")
                                                    .foregroundColor(node.isDirectory ? .blue : .secondary)
                                                
                                                Text(node.name)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            
                                            // 2. Arrow
                                            Image(systemName: "arrow.right")
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                                .frame(maxWidth: .infinity)
                                            
                                            // 3. Destination
                                            if node.isVirtual || node.isImplicitRuleFolder {
                                                Text("Create Folder")
                                                    .foregroundColor(.green)
                                                    .font(.caption)
                                            } else {
                                                Text(node.destinationURL.deletingLastPathComponent().lastPathComponent)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                        }
                                        Divider()
                                            .gridCellColumns(3)
                                            .background(Color.white.opacity(0.1))
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                        }
                    }
                }
                .padding()
                .frame(minWidth: 400)
            }
            
            Divider()
            
            // 4. BOTTOM BAR
            HStack {
                Button(action: { viewModel.selectFolder() }) {
                    Label("Open", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                
                Spacer()
                
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Spacer()
                
                Button(action: { viewModel.execute() }) {
                    Text("Execute Changes")
                        .bold()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(viewModel.stagedChanges.isEmpty)
            }
            .padding(12)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
    }
}
