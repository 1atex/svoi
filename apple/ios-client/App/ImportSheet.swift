import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ImportSheet: View {
  @Environment(\.svoiColors) private var colors
  @ObservedObject var model: SvoiModel
  var profile = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.svoiAccent) private var accent
  @FocusState private var editing: Bool
  @State private var text = ""
  @State private var file = false
  @State private var fileError = ""
  @State private var mode = 0
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Image(systemName: mode == 1 ? "person.2" : "link").font(.system(size: 28)).foregroundStyle(accent)
            .frame(width: 60, height: 60).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
          Picker("Что добавить", selection: $mode) { Text("Подписка").tag(0); Text("Профиль SVOI").tag(1) }.pickerStyle(.segmented)
          VStack(alignment: .leading, spacing: 10) {
            Text(mode == 1 ? "Ваша сеть — по одному коду" : "Добавьте свою подписку").font(.title2.bold())
            Text(mode == 1 ? "Вставьте код SVOI1 с другого устройства. Подписки и параметры профиля перенесутся вместе." : "Скопируйте ссылку у VPN-провайдера. Также можно вставить конфигурацию или выбрать файл.")
              .font(.subheadline).foregroundStyle(SvoiPalette.muted).fixedSize(horizontal: false, vertical: true)
          }
          VStack(alignment: .leading, spacing: 10) {
            Text(mode == 1 ? "Код профиля" : "Ссылка или конфигурация").font(.subheadline.weight(.semibold))
            ZStack(alignment: .topLeading) {
              if text.isEmpty {
                Text(mode == 1 ? "SVOI1.…" : "https://…")
                  .foregroundStyle(SvoiPalette.muted).padding(.horizontal, 6).padding(.vertical, 12).allowsHitTesting(false)
              }
              TextEditor(text: $text).scrollContentBackground(.hidden).frame(minHeight: 140)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($editing)
                .accessibilityLabel(mode == 1 ? "Код профиля" : "Ссылка или конфигурация")
                .accessibilityIdentifier("import-text")
            }
            .padding(10).background(colors.inset, in: RoundedRectangle(cornerRadius: 18))
              .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(editing ? accent : colors.line))
            HStack {
              PasteButton(payloadType: String.self) { values in text = values.first ?? ""; fileError = "" }
                .labelStyle(.titleAndIcon).buttonBorderShape(.roundedRectangle).tint(accent).frame(minHeight: 44)
              Spacer()
              Button { file = true } label: { Label("Из файла", systemImage: "doc") }.frame(minHeight: 44)
            }
          }
          if !model.error.isEmpty || !fileError.isEmpty {
            SvoiNotice(text: fileError.isEmpty ? model.error : fileError, symbol: "exclamationmark.circle")
          }
          Text("VLESS · VMess · Trojan · Shadowsocks · Hysteria2 · JSON Xray")
            .font(.caption).foregroundStyle(SvoiPalette.muted)
          Button {
            editing = false
            Task { await model.add(text); if model.error.isEmpty { dismiss() } }
          } label: {
            HStack(spacing: 10) { if model.working { ProgressView().tint(colors.canvas) }; Text(model.working ? "Импортируем…" : "Добавить в SVOI") }
          }.buttonStyle(SvoiPrimaryButton()).disabled(model.working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("confirm-import")
        }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
      }.scrollDismissesKeyboard(.interactively).background(colors.canvas)
      .navigationTitle("Добавить").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(model.working) }
        ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { editing = false } }
      }
      .onAppear { mode = profile ? 1 : 0 }
      .onChange(of: text) { _ in fileError = "" }
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
  @Environment(\.svoiColors) private var colors
  @ObservedObject var model: SvoiModel
  @State private var code = ""
  @State private var showing = false
  @State private var copied = false
  @State private var preparing = false
  var body: some View {
    Button {
      copied = false
      preparing = true
      Task {
        defer { preparing = false }
        do { code = try await model.exportProfile(); showing = true }
        catch { model.error = error.localizedDescription }
      }
    } label: { Label(preparing ? "Готовим код…" : "Поделиться профилем", systemImage: "square.and.arrow.up") }
    .disabled(model.working || preparing)
    .sheet(isPresented: $showing) {
      NavigationStack {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Image(systemName: "person.2.fill").font(.system(size: 42)).foregroundStyle(SvoiPalette.gold)
          Text("Всё своё — с собой.").font(.title.bold())
          Text("Получатель вставит код в SVOI на другом устройстве и получит подписки и параметры вашего профиля.").foregroundStyle(SvoiPalette.muted)
          SvoiNotice(text: "В коде есть данные доступа. Передавайте его только тем, с кем хотите поделиться подпиской.", symbol: "lock", warning: false)
          ShareLink(item: code) { Label("Передать код", systemImage: "square.and.arrow.up") }.buttonStyle(SvoiPrimaryButton())
          Button { UIPasteboard.general.string = code; copied = true } label: { Label(copied ? "Код скопирован" : "Скопировать код", systemImage: copied ? "checkmark" : "doc.on.doc") }
            .frame(maxWidth: .infinity, minHeight: 44)
        }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }.background(colors.canvas).navigationTitle("Поделиться").navigationBarTitleDisplayMode(.inline)
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { showing = false } } }
      }
    }
  }
}

struct IdentitySettings: View {
  @Environment(\.svoiColors) private var colors
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
          VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption).foregroundStyle(SvoiPalette.muted)
            TextField(label, text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }))
              .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel(label)
          }.padding(.vertical, 5)
        }
      } footer: { Text("Эти значения используются при запросе подписки. Импорт профиля сохраняет параметры отправителя.") }
      .listRowBackground(colors.surface)
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
    .scrollContentBackground(.hidden).background(colors.canvas)
    .navigationTitle("Данные устройства").navigationBarTitleDisplayMode(.inline)
    .onAppear {
      guard fields.isEmpty else { return }
      let identity = model.group["identity"] as? [String: Any] ?? [:]
      fields = Dictionary(uniqueKeysWithValues: labels.map { ($0.0, identity[$0.0] as? String ?? "") })
      sendDevice = identity["omitDeviceHeaders"] as? Bool != true
    }
  }
}
