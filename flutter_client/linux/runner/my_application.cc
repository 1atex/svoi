#include "my_application.h"
#include <flutter_linux/flutter_linux.h>
#include <libayatana-appindicator/app-indicator.h>
#include <unistd.h>
#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** arguments;
  GtkWindow* window;
  FlMethodChannel* channel;
  AppIndicator* indicator;
  GtkWidget* menu;
  gboolean closing;
};
G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void emit(MyApplication* self, const char* method, FlValue* value) {
  if (!self->closing && self->channel != nullptr)
    fl_method_channel_invoke_method(self->channel, method, value, nullptr, nullptr, nullptr);
}
static void reply(FlMethodCall* call, FlValue* value = nullptr) {
  fl_method_call_respond_success(call, value, nullptr);
}
static void fail(FlMethodCall* call, const char* code, const char* message) {
  fl_method_call_respond_error(call, code, message, nullptr, nullptr);
}
static void show(MyApplication* self) {
  if (!self->window || self->closing) return;
  gtk_window_deiconify(self->window);
  gtk_window_present(self->window);
}
static const char* text(FlValue* map, const char* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : "";
}
static bool flag(FlValue* map, const char* key, bool fallback) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL ? fl_value_get_bool(value) : fallback;
}
static void menu_action(GtkMenuItem* item, MyApplication* self) {
  auto id = static_cast<const char*>(g_object_get_data(G_OBJECT(item), "svoi-action"));
  if (!id || !*id) return;
  if (g_str_equal(id, "open")) show(self);
  else { g_autoptr(FlValue) value = fl_value_new_string(id); emit(self, "trayAction", value); }
}
static GtkWidget* make_menu(MyApplication* self, FlValue* items) {
  GtkWidget* menu = gtk_menu_new();
  if (!items || fl_value_get_type(items) != FL_VALUE_TYPE_LIST) return menu;
  for (size_t i = 0; i < fl_value_get_length(items); i++) {
    FlValue* data = fl_value_get_list_value(items, i);
    if (fl_value_get_type(data) != FL_VALUE_TYPE_MAP) continue;
    GtkWidget* item;
    if (flag(data, "separator", false)) item = gtk_separator_menu_item_new();
    else {
      const char* label = text(data, "label");
      item = flag(data, "checked", false) ? gtk_check_menu_item_new_with_label(label) : gtk_menu_item_new_with_label(label);
      if (GTK_IS_CHECK_MENU_ITEM(item)) gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item), TRUE);
      gtk_widget_set_sensitive(item, flag(data, "enabled", true));
      FlValue* children = fl_value_lookup_string(data, "children");
      if (children && fl_value_get_type(children) == FL_VALUE_TYPE_LIST)
        gtk_menu_item_set_submenu(GTK_MENU_ITEM(item), make_menu(self, children));
      else {
        g_object_set_data_full(G_OBJECT(item), "svoi-action", g_strdup(text(data, "id")), g_free);
        g_signal_connect(item, "activate", G_CALLBACK(menu_action), self);
      }
    }
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
  }
  gtk_widget_show_all(menu);
  return menu;
}
static gboolean close_window(gpointer data) {
  auto self = MY_APPLICATION(data);
  // Stop custom callbacks while the Flutter view and messenger are still alive.
  if (self->channel) {
    fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr, nullptr);
    g_clear_object(&self->channel);
  }
  if (self->indicator) app_indicator_set_status(self->indicator, APP_INDICATOR_STATUS_PASSIVE);
  g_clear_object(&self->indicator);
  if (self->menu) { gtk_widget_destroy(self->menu); g_clear_object(&self->menu); }
  if (self->window) gtk_window_close(self->window);
  return G_SOURCE_REMOVE;
}
static void handle(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  auto self = MY_APPLICATION(user_data);
  const char* name = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (self->closing) { reply(call); return; }
  if (g_str_equal(name, "ready")) reply(call);
  else if (g_str_equal(name, "show")) { show(self); reply(call); }
  else if (g_str_equal(name, "tray") || g_str_equal(name, "minimize")) {
    gtk_window_iconify(self->window); reply(call);
  } else if (g_str_equal(name, "close")) {
    const bool queued = self->closing;
    self->closing = TRUE;
    reply(call);
    if (!queued)
      g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, close_window, g_object_ref(self), g_object_unref);
  } else if (g_str_equal(name, "requestWindowClose")) {
    emit(self, "requestClose", nullptr); reply(call);
  } else if (g_str_equal(name, "updateTray")) {
    if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      GtkWidget* menu = make_menu(self, fl_value_lookup_string(args, "items"));
      g_object_ref_sink(menu);
      app_indicator_set_menu(self->indicator, GTK_MENU(menu));
      if (self->menu) { gtk_widget_destroy(self->menu); g_object_unref(self->menu); }
      self->menu = menu;
      app_indicator_set_title(self->indicator, text(args, "tooltip"));
    }
    reply(call);
  } else if (g_str_equal(name, "titlebar")) reply(call);
  else if (g_str_equal(name, "openCommunity") || g_str_equal(name, "openExternal")) {
    const bool community = g_str_equal(name, "openCommunity");
    const char* uri = community ? "tg://resolve?domain=SVOI_client" :
      args && fl_value_get_type(args) == FL_VALUE_TYPE_STRING ? fl_value_get_string(args) : "";
    g_autoptr(GError) error = nullptr;
    g_autoptr(GUri) parsed = g_uri_parse(uri, G_URI_FLAGS_NONE, &error);
    const char* scheme = parsed ? g_uri_get_scheme(parsed) : nullptr;
    if (!scheme || (g_strcmp0(scheme, "https") && g_strcmp0(scheme, "http") && g_strcmp0(scheme, "tg")) ||
        !g_uri_get_host(parsed) || g_uri_get_userinfo(parsed)) {
      fail(call, "invalid_uri", "Недопустимая ссылка"); return;
    }
    g_clear_error(&error);
    g_autoptr(GAppInfo) app = g_app_info_get_default_for_uri_scheme(scheme);
    if (community && !app) { fail(call, "telegram_missing", "Установите Telegram"); return; }
    if (!g_app_info_launch_default_for_uri(uri, nullptr, &error))
      fail(call, "launch_failed", "Не удалось открыть приложение для ссылки");
    else reply(call);
  } else if (g_str_equal(name, "openFile") || g_str_equal(name, "saveFile")) {
    const bool save = g_str_equal(name, "saveFile");
    GtkWidget* dialog = gtk_file_chooser_dialog_new(save ? "Сохранить файл" : "Открыть профиль", self->window,
      save ? GTK_FILE_CHOOSER_ACTION_SAVE : GTK_FILE_CHOOSER_ACTION_OPEN,
      "Отмена", GTK_RESPONSE_CANCEL, save ? "Сохранить" : "Открыть", GTK_RESPONSE_ACCEPT, nullptr);
    if (save) {
      gtk_file_chooser_set_do_overwrite_confirmation(GTK_FILE_CHOOSER(dialog), TRUE);
      if (args && fl_value_get_type(args) == FL_VALUE_TYPE_STRING) {
        g_autofree char* base = g_path_get_basename(fl_value_get_string(args));
        gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(dialog), base);
      }
    }
    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
      g_autofree char* path = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
      g_autoptr(FlValue) result = fl_value_new_string(path); reply(call, result);
    } else reply(call);
    gtk_widget_destroy(dialog);
  } else fl_method_call_respond_not_implemented(call, nullptr);
}
static gboolean on_delete(GtkWidget*, GdkEvent*, gpointer user_data) {
  auto self = MY_APPLICATION(user_data);
  if (self->closing) return FALSE;
  gtk_widget_set_sensitive(GTK_WIDGET(self->window), FALSE);
  emit(self, "requestClose", nullptr);
  return TRUE;
}
static gboolean on_state(GtkWidget*, GdkEventWindowState* event, gpointer user_data) {
  auto self = MY_APPLICATION(user_data);
  g_autoptr(FlValue) value = fl_value_new_bool(!(event->new_window_state & GDK_WINDOW_STATE_ICONIFIED));
  emit(self, "visibility", value);
  return FALSE;
}
static void first_frame(MyApplication* self, FlView*) {
  if (self->window && !self->closing) gtk_widget_show(GTK_WIDGET(self->window));
}
static void on_window_destroy(GtkWidget*, gpointer data) {
  MY_APPLICATION(data)->window = nullptr;
}
static void activate(GApplication* application) {
  auto self = MY_APPLICATION(application);
  if (self->window) { show(self); return; }
  self->window = GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_title(self->window, "SVOI");
  gtk_window_set_default_size(self->window, 1220, 840);
  GdkGeometry geometry{}; geometry.min_width = 800; geometry.min_height = 600;
  gtk_window_set_geometry_hints(self->window, nullptr, &geometry, GDK_HINT_MIN_SIZE);
  gtk_window_set_icon_name(self->window, "dev.svoi.app");
  g_signal_connect(self->window, "delete-event", G_CALLBACK(on_delete), self);
  g_signal_connect(self->window, "destroy", G_CALLBACK(on_window_destroy), self);
  g_signal_connect(self->window, "window-state-event", G_CALLBACK(on_state), self);
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  // Impeller's background shader work races Mesa/LLVM teardown on Linux.
  fl_dart_project_set_enable_impeller(project, FALSE);
  fl_dart_project_set_dart_entrypoint_arguments(project, self->arguments);
  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(self->window), GTK_WIDGET(view));
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)),
    "dev.svoi/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, handle, self, nullptr);
  g_autofree char* exe = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree char* folder = exe ? g_path_get_dirname(exe) : g_get_current_dir();
  g_autofree char* icon = g_build_filename(folder, "data", "flutter_assets", "assets", "svoi-mark.png", nullptr);
  gtk_window_set_icon_from_file(self->window, icon, nullptr);
  g_autofree char* tray_icon = g_build_filename(folder, "data", "flutter_assets", "assets", "svoi-tray.png", nullptr);
  self->indicator = app_indicator_new("svoi", tray_icon, APP_INDICATOR_CATEGORY_COMMUNICATIONS);
  app_indicator_set_status(self->indicator, APP_INDICATOR_STATUS_ACTIVE);
  self->menu = gtk_menu_new();
  g_object_ref_sink(self->menu);
  app_indicator_set_menu(self->indicator, GTK_MENU(self->menu));
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame), self);
  gtk_widget_realize(GTK_WIDGET(view));
  gtk_widget_grab_focus(GTK_WIDGET(view));
}
static gboolean local_command_line(GApplication* application, gchar*** arguments, int* status) {
  auto self = MY_APPLICATION(application);
  self->arguments = g_strdupv(*arguments + 1);
  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) { *status = 1; return TRUE; }
  g_application_activate(application); *status = 0; return TRUE;
}
static void dispose(GObject* object) {
  auto self = MY_APPLICATION(object);
  g_clear_object(&self->channel);
  g_clear_object(&self->indicator);
  if (self->menu) { gtk_widget_destroy(self->menu); g_clear_object(&self->menu); }
  g_clear_pointer(&self->arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}
static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = activate;
  G_APPLICATION_CLASS(klass)->local_command_line = local_command_line;
  G_OBJECT_CLASS(klass)->dispose = dispose;
}
static void my_application_init(MyApplication*) {}
MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);
  return MY_APPLICATION(g_object_new(my_application_get_type(), "application-id", APPLICATION_ID,
    "flags", static_cast<GApplicationFlags>(0), nullptr));
}
