# Структура исходников

Текущее приложение для Windows состоит из Flutter-интерфейса, локального Go backend и Xray. Инструкция сборки и тестирования — в [flutter_client/README.md](../flutter_client/README.md).

| Путь | Назначение |
| --- | --- |
| `flutter_client/` | Интерфейс, Windows runner, тесты, установщик и сборка текущего приложения |
| `backend/*.go` | Подписки, профили, Xray, TUN, маршрутизация, zapret, обновления и автозапуск |
| `backend/*_test.go` | Проверки backend и интеграции с Windows |
| `go.mod`, `go.sum` | Зависимости Go и их контрольные суммы |
| `scripts/prepare-core.ps1`, `core/` | Загрузка закреплённой версии Xray, сведения об источнике и лицензии |
| `assets/`, `licenses/` | Иконки, исходники оформления и лицензии зависимостей |
| `.github/workflows/release.yml` | Проверки, сборка и публикация текущего Windows-клиента |

## Прежний веб-интерфейс

`backend/web/` пока встроен в Go-сервис через `go:embed`; `backend/desktop_windows.go` используется при сборке без `native_core`. Это действующие зависимости исходников. Отдельные установщик и выпуск WebView-клиента больше не поддерживаются.

`backend/package.json`, `backend/package-lock.json` и `backend/tests/` нужны для регрессионных проверок этого интерфейса. Node.js не входит в приложение. Проверки из корня репозитория:

```powershell
npm --prefix backend ci --ignore-scripts
npm --prefix backend test
go test ./...
go test -tags native_core ./...
go vet ./...
```

Текущая сборка использует `backend/desktop_native_windows.go` и тег `native_core`. Файлы `*_windows.go` и `*_other.go` выбираются Go по платформе: это не дубликаты. Удалять их или тесты ради сокращения списка файлов не требуется.
