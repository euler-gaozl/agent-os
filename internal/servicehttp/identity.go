package servicehttp

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strings"
)

type identityKey struct{}

func Caller(ctx context.Context) string { v, _ := ctx.Value(identityKey{}).(string); return v }
func TokenHash(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

// Peers contain hashes only. A service cannot impersonate another service by
// reading its inbound authorization configuration.
func peer(c Config, r *http.Request) string {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if len(token) < 32 {
		return ""
	}
	hash := TokenHash(token)
	for role, expected := range c.Peers {
		if hash == expected {
			return role
		}
	}
	return ""
}
func permitted(service, caller, method, path string) bool {
	if path == "/readyz" || path == "/metrics" {
		return caller == service || caller == "control"
	}
	if service == "runtime" && path == "/v1/instances" && method == "POST" {
		return caller != ""
	}
	get := method == "GET"
	switch service {
	case "sources":
		return (caller == "sources" && method == "POST" && path == "/mcp") || (caller == "control" && get && strings.HasPrefix(path, "/captures/"))
	case "registry":
		if caller == "control" {
			return !strings.HasPrefix(path, "/v1/credentials/resolve")
		}
		if caller == "futures" {
			return get && (path == "/v1/status" || path == "/v1/published/futures")
		}
		if caller == "runtime" && get && strings.HasPrefix(path, "/v1/published/") {
			return true
		}
		if caller == "runtime" || caller == "worker" || caller == "knowledge" || caller == "indexer" || caller == "toolhub" || caller == "telemetry" {
			return (get && strings.HasPrefix(path, "/v1/resources/")) || (method == "POST" && path == "/v1/credentials/resolve")
		}
	case "toolhub":
		if caller == "runtime" && method == "POST" && path == "/v1/skill-file" {
			return true
		}
		if caller == "control" {
			return strings.HasPrefix(path, "/v1/assets") || path == "/v1/discover"
		}
		if caller == "registry" {
			return (get && strings.HasPrefix(path, "/v1/resolve/")) || (method == "POST" && path == "/v1/assets")
		}
		if caller == "runtime" || caller == "worker" {
			return (get && strings.HasPrefix(path, "/v1/resolve/")) || (caller == "worker" && method == "POST" && path == "/invoke")
		}
	case "runtime":
		if caller == "telemetry" {
			return method == "POST" && (path == "/v1/telemetry/claim" || path == "/v1/telemetry/ack")
		}
		if caller == "sandbox" {
			return method == "POST" && path == "/v1/sandbox/authorize"
		}
		if caller == "control" {
			return strings.HasPrefix(path, "/v1/runs") || path == "/v1/status" ||
				((get || method == "POST") && path == "/v1/documents") ||
				(get && strings.HasPrefix(path, "/v1/documents/"))
		}
		if caller == "futures" {
			return path == "/v1/apps/futures/runs" || strings.HasPrefix(path, "/v1/apps/futures/runs/")
		}
		if caller == "toolhub" {
			return (get && strings.HasPrefix(path, "/v1/runs/")) || (method == "POST" && path == "/invoke")
		}
		if caller == "knowledge" {
			return get && strings.HasPrefix(path, "/v1/runs/")
		}
	case "knowledge":
		if caller == "control" {
			return strings.HasPrefix(path, "/v1/") && path != "/v1/retrieve" && path != "/v1/document"
		}
		if caller == "futures" {
			return get && path == "/v1/status"
		}
		if caller == "runtime" {
			return method == "POST" && (path == "/v1/retrieve" || path == "/v1/document")
		}
	case "storage":
		if caller == "runtime" || caller == "worker" {
			return method == "PUT" && strings.HasPrefix(path, "/v1/artifacts/") || caller == "runtime" && method == "POST" && path == "/v1/artifacts/page"
		}
		return caller == "control" && ((get && strings.HasPrefix(path, "/artifacts/")) || (method == "POST" && path == "/gc"))
	case "sandbox":
		return caller == "runtime" && method == "POST" && path == "/execute"
	}
	return false
}
