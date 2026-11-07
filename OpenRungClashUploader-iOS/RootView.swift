import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showImporter = false
    @State private var showFolderPrompt = false
    @State private var folderName = ""
    @State private var itemToRename: FTPItem?
    @State private var newItemName = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Group {
                        Button(action: model.fetchOpenRung) { Label("获取 OpenRung 订阅", systemImage: "arrow.down.circle") }.buttonStyle(PrimaryButton())
                        Button(action: model.fetchZhuhai) { Label("获取 Zhuhai 订阅", systemImage: "arrow.down.circle") }.buttonStyle(SecondaryButton())
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("YAML 预览").font(.headline); Spacer(); Text("\(model.yaml.utf8.count) 字节").font(.caption).foregroundColor(.secondary) }
                        TextEditor(text: $model.yaml).font(.system(.caption, design: .monospaced)).frame(minHeight: 240).padding(6).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
                        Button(action: model.upload) { Label("上传订阅", systemImage: "arrow.up.doc") }.buttonStyle(PrimaryButton()).disabled(model.yaml.isEmpty)
                    }.padding().background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 16)).shadow(color: .black.opacity(0.06), radius: 5)
                    settings
                    VStack(alignment: .leading, spacing: 8) { HStack { Text("状态").font(.headline); Spacer(); Button("清空") { model.log = "" }.font(.subheadline) }; Text(model.log.isEmpty ? "无日志" : model.log).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.padding().frame(maxWidth: .infinity).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 14))
                    Button { model.connectFTP() } label: { Label("连接 FTP / 文件管理", systemImage: "folder.badge.gearshape") }.buttonStyle(SecondaryButton())
                }.padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("订阅管理")
            .toolbar { if model.isBusy { ToolbarItem(placement: .navigationBarTrailing) { ProgressView() } } }
            .sheet(isPresented: $model.showFTP) { ftpSheet }
            .alert("提示", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) { Button("好", role: .cancel) { model.alertMessage = nil } } message: { Text(model.alertMessage ?? "") }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                do { guard let url = try result.get().first else { return }; let secured = url.startAccessingSecurityScopedResource(); defer { if secured { url.stopAccessingSecurityScopedResource() } }; model.uploadPickedFile(try Data(contentsOf: url), name: url.lastPathComponent) } catch { model.alertMessage = error.localizedDescription }
            }
            .alert("新建文件夹", isPresented: $showFolderPrompt) { TextField("文件夹名称", text: $folderName); Button("取消", role: .cancel) {}; Button("创建") { model.makeFolder(folderName); folderName = "" } }
            .alert("重命名", isPresented: Binding(get: { itemToRename != nil }, set: { if !$0 { itemToRename = nil } })) { TextField("新名称", text: $newItemName); Button("取消", role: .cancel) { itemToRename = nil }; Button("确定") { if let item = itemToRename { model.renameFTP(item, to: newItemName) }; itemToRename = nil } }
        }
        .navigationViewStyle(.stack)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FTP 设置").font(.headline)
            field("服务器", text: $model.host, keyboard: .URL)
            HStack { field("端口", text: $model.port, keyboard: .numberPad); field("账号", text: $model.username) }
            SecureField("FTP 密码", text: $model.password).textFieldStyle(.roundedBorder)
            field("上传路径", text: $model.remotePath, keyboard: .URL)
            Button("保存设置", action: model.saveSettings).font(.subheadline).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding().background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View { TextField(title, text: text).keyboardType(keyboard).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder) }

    private var ftpSheet: some View {
        NavigationView {
            List {
                Section { HStack { Text("/"); if !model.ftpPath.isEmpty { Text(model.ftpPath).lineLimit(1) }; Spacer(); Button("上级") { model.goFTPParent() }; Button("刷新") { model.refreshFTP() } } }
                Section {
                    ForEach(model.ftpItems) { item in
                        HStack {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                            Text(item.name).lineLimit(1)
                            Spacer()
                            if item.isDirectory { Button("打开") { model.openFolder(item.name) } }
                            else if item.name.lowercased().hasSuffix(".yaml") || item.name.lowercased().hasSuffix(".asp") { Button("上传覆盖") { model.upload() } }
                            Button("改名") { itemToRename = item; newItemName = item.name }
                            Button(role: .destructive) { model.deleteFTP(item) } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }
            .navigationTitle("FTP 文件")
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { model.showFTP = false } }; ToolbarItemGroup(placement: .navigationBarTrailing) { Button { showFolderPrompt = true } label: { Image(systemName: "folder.badge.plus") }; Button { showImporter = true } label: { Image(systemName: "square.and.arrow.up") } } }
        }.navigationViewStyle(.stack)
    }
}

struct PrimaryButton: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.font(.headline).frame(maxWidth: .infinity).padding().background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1)).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 13)) } }
struct SecondaryButton: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.font(.headline).frame(maxWidth: .infinity).padding().background(Color(.secondarySystemBackground)).foregroundColor(.accentColor).clipShape(RoundedRectangle(cornerRadius: 13)) } }
