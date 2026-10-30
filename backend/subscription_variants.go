package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Servers live only in Group.Servers. Statuses describe the corresponding
// SubscriptionCore cache, including its last-good report/metadata on failure.
type SubscriptionVariantStatus struct {
	State     string                `json:"state"`
	Count     int                   `json:"count"`
	Report    *Report               `json:"report,omitempty"`
	Metadata  *SubscriptionMetadata `json:"metadata,omitempty"`
	Error     string                `json:"error,omitempty"`
	Stale     bool                  `json:"stale"`
	CheckedAt time.Time             `json:"checkedAt"`
}

var subscriptionVariantCores = []string{"xray", "sing-box", "mihomo"}

type subscriptionVariantResult struct {
	Core        string
	Parsed      ParsedSubscription
	Body        []byte
	Report      *Report
	Metadata    *SubscriptionMetadata
	Err         error
	Unavailable bool
	CheckedAt   time.Time
}

func subscriptionFormatCore(format string) string {
	if format == "sing-box" || format == "mihomo" {
		return format
	}
	return "xray"
}
func subscriptionServerCore(server ServerConfig) string {
	if server.SubscriptionCore != "" {
		return server.SubscriptionCore
	}
	if server.SourceProfileCore != "" {
		return server.SourceProfileCore
	}
	return "xray"
}

func fetchSubscriptionResponse(ctx context.Context, client *http.Client, raw string, identity Identity, format string) subscriptionVariantResult {
	result := subscriptionVariantResult{Core: subscriptionFormatCore(format), CheckedAt: time.Now().UTC()}
	req, err := http.NewRequestWithContext(ctx, "GET", raw, nil)
	if err != nil {
		result.Err = fail(502, "Не удалось создать запрос подписки")
		return result
	}
	for key, value := range headers(identity) {
		req.Header.Set(key, value)
	}
	applySubscriptionFormatHeaders(req.Header, format)
	response, err := client.Do(req)
	if err != nil {
		result.Err = fail(502, "Не удалось загрузить подписку. Проверьте адрес и доступность сервера.")
		return result
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		result.Err = fail(502, fmt.Sprintf("Сервер подписки вернул HTTP %d. Перенаправления отключены.", response.StatusCode))
		return result
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, nativeProviderMaxBytes+1))
	if err != nil {
		result.Err = fail(502, "Не удалось прочитать подписку")
		return result
	}
	if len(body) > nativeProviderMaxBytes {
		result.Err = fail(413, "Подписка превышает 4 МБ")
		return result
	}
	parsed, err := parseSubscriptionWithFormat(body, format)
	if err != nil {
		var api apiError
		code := 422
		if errors.As(err, &api) && api.status == 413 {
			code = 413
		}
		message := "Провайдер вернул некорректный или неподдерживаемый формат подписки; рабочий кеш сохранён"
		if code == 413 {
			message = "Подписка превышает допустимый размер; рабочий кеш сохранён"
		}
		if strings.Contains(err.Error(), "HTML-страницу") {
			message = "Провайдер вернул HTML-страницу вместо подписки. Проверьте ссылку и авторизацию"
		}
		result.Err = fail(code, message)
		return result
	}
	if len(parsed.Servers) == 0 {
		result.Err = fail(422, "Провайдер вернул пустую подписку; рабочий кеш сохранён")
		return result
	}
	result.Parsed, result.Body = parsed, body
	result.Report = &Report{Count: len(parsed.Servers), Format: parsed.Format, FetchedAt: time.Now().UTC(), Warnings: parsed.Warnings}
	result.Metadata = mergeSubscriptionMetadata(parsed.MetadataHeaders, response.Header)
	return result
}

func validateSubscriptionVariant(result subscriptionVariantResult) subscriptionVariantResult {
	if result.Err != nil {
		return result
	}
	for _, server := range result.Parsed.Servers {
		actual := server.SourceProfileCore
		if actual == "" {
			actual = "xray"
		}
		if actual != result.Core {
			result.Unavailable = true
			if result.Core == "xray" {
				result.Err = fail(422, "Провайдер не выдал вариант Xray для основного User-Agent; получен профиль другого ядра")
			} else if actual == "xray" {
				result.Err = fail(422, "Провайдер не выдал нативный формат "+coreName(result.Core)+"; получена подписка Xray. Отдельный нативный вариант не создан")
			} else {
				result.Err = fail(422, "Провайдер вернул профиль другого ядра вместо "+coreName(result.Core))
			}
			return result
		}
	}
	return result
}

func fetchSubscriptionVariants(ctx context.Context, client *http.Client, raw string, identity Identity) (map[string]subscriptionVariantResult, error) {
	return fetchSubscriptionVariantsWithin(ctx, client, raw, identity, 22*time.Second)
}

func fetchSubscriptionVariantsWithin(parent context.Context, client *http.Client, raw string, identity Identity, timeout time.Duration) (map[string]subscriptionVariantResult, error) {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	completed := make(chan subscriptionVariantResult, 3)
	for _, format := range []string{"auto", "sing-box", "mihomo"} {
		go func(format string) {
			completed <- validateSubscriptionVariant(fetchSubscriptionResponse(ctx, client, raw, identity, format))
		}(format)
	}
	results := make(map[string]subscriptionVariantResult, 3)
	for range subscriptionVariantCores {
		select {
		case result := <-completed:
			results[result.Core] = result
		case <-ctx.Done():
			if parent.Err() != nil {
				return nil, parent.Err()
			}
			finishSubscriptionVariantTimeout(results, completed)
			return results, nil
		}
	}
	return results, nil
}

func finishSubscriptionVariantTimeout(results map[string]subscriptionVariantResult, completed <-chan subscriptionVariantResult) {
	// A completed format may already be queued when select chooses the expired
	// deadline. Drain those results before marking only the missing formats stale.
	draining := true
	for draining {
		select {
		case result, ok := <-completed:
			if !ok {
				draining = false
			} else {
				results[result.Core] = result
			}
		default:
			draining = false
		}
	}
	for _, core := range subscriptionVariantCores {
		if _, done := results[core]; !done {
			results[core] = subscriptionVariantResult{Core: core, Err: fail(504, "Провайдер не ответил вовремя для этого формата; рабочий кеш сохранён"), CheckedAt: time.Now().UTC()}
		}
	}
}

func subscriptionVariantIDs(subscriptionID, core string, servers []ServerConfig) []ServerConfig {
	result := make([]ServerConfig, len(servers))
	for index, server := range servers {
		server.SubscriptionID, server.SubscriptionCore = subscriptionID, core
		if core == "xray" {
			if subscriptionID != "legacy" {
				server.ID = subscriptionID + "-" + server.ID
			}
		} else {
			server.ID = subscriptionID + "-" + core + "-" + server.ID
		}
		result[index] = server
	}
	return result
}

func applySubscriptionVariants(g *Group, sub *Subscription, results map[string]subscriptionVariantResult, preferred string) (*Report, error) {
	preferred = subscriptionFormatCore(preferred)
	cache := make(map[string][]ServerConfig)
	kept := make([]ServerConfig, 0, len(g.Servers))
	for _, server := range g.Servers {
		if server.SubscriptionID != sub.ID {
			kept = append(kept, server)
		} else {
			core := subscriptionServerCore(server)
			cache[core] = append(cache[core], server)
		}
	}
	statuses := make(map[string]SubscriptionVariantStatus, 3)
	for _, core := range subscriptionVariantCores {
		status := sub.Variants[core]
		if status.Report == nil && len(cache[core]) > 0 {
			status.Report, status.Metadata = sub.Report, sub.Metadata
		}
		result, attempted := results[core]
		if attempted {
			status.CheckedAt = result.CheckedAt
			if result.Err == nil {
				cache[core] = subscriptionVariantIDs(sub.ID, core, result.Parsed.Servers)
				status.State, status.Report, status.Metadata, status.Error, status.Stale = "ready", result.Report, result.Metadata, "", false
			} else {
				status.State = "error"
				if result.Unavailable {
					status.State = "unavailable"
				}
				// API errors are already static/redacted; never store URL/transport errors.
				status.Error = result.Err.Error()
				status.Stale = len(cache[core]) > 0
			}
		}
		status.Count = len(cache[core])
		statuses[core] = status
	}
	order := []string{preferred}
	for _, core := range subscriptionVariantCores {
		if core != preferred {
			order = append(order, core)
		}
	}
	for _, core := range order {
		kept = append(kept, cache[core]...)
	}
	g.Servers, sub.Variants = kept, statuses
	var chosen *subscriptionVariantResult
	for _, core := range order {
		if result, ok := results[core]; ok && result.Err == nil {
			copy := result
			chosen = &copy
			break
		}
	}
	if chosen == nil {
		syncLegacySubscription(g)
		if result, ok := results[preferred]; ok && result.Err != nil {
			return nil, result.Err
		}
		return nil, fail(502, "Не удалось обновить ни один формат подписки; рабочий кеш сохранён")
	}
	report := *chosen.Report
	report.Warnings = append([]string(nil), chosen.Report.Warnings...)
	missing := []string{}
	for _, core := range subscriptionVariantCores {
		if result, ok := results[core]; ok && result.Err != nil {
			missing = append(missing, coreName(core))
		}
	}
	if len(missing) > 0 {
		report.Warnings = append(report.Warnings, "Не обновлены варианты: "+strings.Join(missing, ", ")+". Ранее полученный кеш этих вариантов сохранён, если он есть")
	}
	sub.Report, sub.Metadata = &report, chosen.Metadata
	syncLegacySubscription(g)
	return &report, nil
}
