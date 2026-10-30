package main

import "strings"

func effectiveProbeSettings(settings ProbeSettings, metadata *SubscriptionMetadata) ProbeSettings {
	settings.defaults()
	if settings.URLSource == "custom" || (settings.URLSource == "" && settings.URL != defaultProbeURL) || metadata == nil {
		return settings
	}
	candidate := settings
	candidate.URL = strings.TrimSpace(metadata.Hints["check-url-via-proxy"])
	if candidate.URL != "" && validateProbeSettings(&candidate) == nil {
		settings.URL = candidate.URL
	}
	return settings
}

func serverProbeSettings(settings ProbeSettings, g *Group, server ServerConfig) ProbeSettings {
	for _, subscription := range g.Subscriptions {
		if subscription.ID == server.SubscriptionID {
			if variant, ok := subscription.Variants[server.SubscriptionCore]; ok {
				return effectiveProbeSettings(settings, variant.Metadata)
			}
			return effectiveProbeSettings(settings, subscription.Metadata)
		}
	}
	settings.defaults()
	return settings
}
