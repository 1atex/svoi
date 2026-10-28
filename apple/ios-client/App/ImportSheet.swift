import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ImportSheet: View {
  @ObservedObject var model: SvoiModel
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var file = false
  @State private var fileError = ""
  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextEditor(text: $text).frame(minHeight: 170).textInputAutocapitalization(.never).autocorrectionDisabled()
          Button("Вставить из буфера") { text = UIPasteboard.general.string ?? "" }
          Button("Выбрать файл") { file = true }
        } header: { Text("Ссылка, конфигурация или код SVOI1") }
        footer: { Text("Поддерживаются ссылки подписок, VLESS, VMess, Trojan, Shadowsocks, Hysteria2 и JSON-профили Xray.") }
        if !model.error.isEmpty || !fileError.isEmpty { Section { Text(fileError.isEmpty ? model.error : fileError).foregroundStyle(.orange).textSelection(.enabled) } }
        Section {
          Button {
            Task {
              await model.add(text)
              if model.error.isEmpty { dismiss() }
            }
          } label: {
            HStack { Text(model.working ? "Импортируем…" : "Импортировать"); Spacer(); if model.working { ProgressView() } }
          }.disabled(model.working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .navigationTitle("Добавить в SVOI")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(model.working) } }
      .interactiveDismissDisabled(model.working)
      .fileImporter(isPresented: $file, allowedContentTypes: [.plainText, .json, .data]) { result in
        do {
          let url = try result.get()
          let scope = url.startAccessingSecurityScopedResource()
          defer { if scope { url.stopAccessingSecurityScopedResource() } }
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= 4 * 1024 * 1024 else { throw SvoiError("Файл превышает 4 МБ") }
          let data = try Data(contentsOf: url, options: .mappedIfSafe)
          guard data.count <= 4 * 1024 * 1024, let content = String(data: data, encoding: .utf8) else { throw SvoiError("Нужен текстовый файл UTF-8 размером до 4 МБ") }
          text = content
          fileError = ""
        } catch { fileError = error.localizedDescription }
      }
    }
  }
}

struct ShareProfileButton: View {
  @ObservedObject var model: SvoiModel
  @State private var code = ""
  @State private var showing = false
  var body: some View {
    Button("Поделиться профилем") {
      Task {
        do { code = try await model.exportProfile(); showing = true }
        catch { model.error = error.localizedDescription }
      }
    }
    .disabled(model.working)
    .sheet(isPresented: $showing) {
      NavigationStack {
        VStack(alignment: .leading, spacing: 22) {
          Text("Код содержит данные профиля и подписок. Передавайте его только тем, с кем хотите поделиться доступом.").foregroundStyle(.secondary)
          ShareLink(item: code) { Label("Передать код", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
          Button("Скопировать код") { UIPasteboard.general.string = code }
          Spacer()
        }.padding(24).navigationTitle("Общий профиль")
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { showing = false } } }
      }
    }
  }
}

struct IdentitySettings: View {
  @ObservedObject var model: SvoiModel
  @State private var fields: [String: String] = [:]
  @State private var sendDevice = true
  @State private var saving = false
  @State private var message = ""
  private let labels = [("hwid", "HWID"), ("os", "ОС"), ("model", "Устройство"), ("locale", "Язык"), ("userAgent", "User-Agent")]
  var body: some View {
    Form {
      Section {
        Toggle("Отправлять данные устройства", isOn: $sendDevice)
        ForEach(labels, id: \.0) { key, label in
          TextField(label, text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
      } footer: { Text("Эти значения используются при запросе подписки. Импорт профиля сохраняет параметры отправителя.") }
      if !message.isEmpty { Section { Text(message).foregroundStyle(.orange) } }
      Button(saving ? "Сохраняем…" : "Сохранить") {
        let profile = model.profileID
        saving = true
        Task {
          defer { saving = false }
          do {
            guard profile == model.profileID else { throw SvoiError("Профиль изменился. Откройте настройки заново.") }
            var identity: [String: Any] = fields
            identity["omitDeviceHeaders"] = !sendDevice
            try await model.updateIdentity(identity)
            message = "Сохранено. Новые параметры применятся при обновлении подписок."
          } catch { message = error.localizedDescription }
        }
      }.disabled(saving || model.working)
    }
    .navigationTitle("Данные устройства")
    .onAppear {
      guard fields.isEmpty else { return }
      let identity = model.group["identity"] as? [String: Any] ?? [:]
      fields = Dictionary(uniqueKeysWithValues: labels.map { ($0.0, identity[$0.0] as? String ?? "") })
      sendDevice = identity["omitDeviceHeaders"] as? Bool != true
    }
  }
}
