package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"regexp"
	"strings"
)

var roles = []string{"control", "registry", "runtime", "worker", "toolhub", "knowledge", "indexer", "storage", "sandbox", "futures", "telemetry", "sources"}
var domains = []string{"registry", "runtime", "toolhub", "knowledge", "storage", "sandbox", "telemetry", "sources"}

type plan struct {
	Format           int                          `json:"format"`
	Prefix           string                       `json:"prefix"`
	AdminDatabaseURL string                       `json:"admin_database_url"`
	AdminToken       string                       `json:"admin_token"`
	BusinessToken    string                       `json:"business_token"`
	MasterKey        string                       `json:"master_key"`
	Endpoints        map[string]string            `json:"endpoints"`
	Options          map[string]map[string]string `json:"options,omitempty"`
}
type checkpoint struct {
	Format     int               `json:"format"`
	ID         string            `json:"id"`
	PlanHash   string            `json:"plan_hash"`
	Identities map[string]string `json:"identities"`
	Passwords  map[string]string `json:"passwords"`
	ClusterID  string            `json:"cluster_id"`
	Prefix     string            `json:"prefix"`
	Roles      map[string]uint32 `json:"roles"` // zero is a persisted create intent
	Databases  map[string]uint32 `json:"databases"`
	Complete   bool              `json:"complete"`
}
type target struct {
	Owner    string            `json:"owner"`
	Database string            `json:"database"`
	Roles    map[string]string `json:"roles"`
}

func readPlan(file string) (plan, error) {
	var p plan
	b, err := readPrivate(file)
	if err != nil {
		return p, err
	}
	if len(b) > 64<<10 {
		return p, errors.New("plan exceeds 64 KiB")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if err = d.Decode(&p); err != nil {
		return p, err
	}
	if d.Decode(new(any)) != io.EOF {
		return p, errors.New("single bounded plan object required")
	}
	return p, p.validate()
}
func (p plan) validate() error {
	if p.Format != 1 || !regexp.MustCompile(`^agentos_[a-z][a-z0-9_]{0,23}$`).MatchString(p.Prefix) {
		return errors.New("invalid deployment prefix")
	}
	u, err := url.Parse(p.AdminDatabaseURL)
	if err != nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") || u.Hostname() == "" || u.User == nil || u.User.Username() == "" || u.Fragment != "" || u.Path != "/postgres" {
		return errors.New("explicit PostgreSQL URI for the fixed postgres maintenance database required")
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return errors.New("invalid connection query")
	}
	for key, values := range q {
		if key != "sslmode" || len(values) != 1 {
			return errors.New("connection identity overrides forbidden")
		}
	}
	if mode := q.Get("sslmode"); mode != "disable" && mode != "require" && mode != "verify-full" {
		return errors.New("explicit sslmode required")
	}
	if len(p.AdminToken) < 32 || len(p.BusinessToken) < 32 || p.AdminToken == p.BusinessToken {
		return errors.New("distinct user identities required")
	}
	master, err := hex.DecodeString(p.MasterKey)
	if err != nil || len(master) != 32 {
		return errors.New("32-byte master key required")
	}
	if len(p.Endpoints) != len(roles) {
		return errors.New("complete service endpoints required")
	}
	for _, role := range roles {
		u, err := url.Parse(p.Endpoints[role])
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
			return errors.New("invalid service endpoint")
		}
	}
	allowed := map[string]string{
		"runtime": "MCP_ALLOWED_HOSTS", "worker": "MCP_ALLOWED_HOSTS,AGENTOS_NODE,DSH_RUNNER",
		"toolhub": "MCP_ALLOWED_HOSTS", "sources": "SOURCE_ALLOWED_HOSTS",
		"sandbox": "SANDBOX_IMAGE,DOCKER_HOST", "telemetry": "LANGFUSE_URL",
	}
	for role, options := range p.Options {
		if _, ok := allowed[role]; !ok {
			return errors.New("unknown service options scope")
		}
		for key, value := range options {
			if !strings.Contains(","+allowed[role]+",", ","+key+",") || key == "" || len(value) > 4096 || strings.ContainsRune(value, '\x00') {
				return errors.New("unapproved service option")
			}
		}
	}
	return nil
}
func domain(role string) string {
	switch role {
	case "control", "futures":
		return ""
	case "worker":
		return "runtime"
	case "indexer":
		return "knowledge"
	default:
		return role
	}
}
func randomID() (string, error) {
	var b [32]byte
	_, err := rand.Read(b[:])
	return hex.EncodeToString(b[:]), err
}
func hash(b []byte) string   { v := sha256.Sum256(b); return hex.EncodeToString(v[:]) }
func planHash(p plan) string { b, _ := json.Marshal(p); return hash(b) }
func newCheckpoint(p plan, cluster string) (checkpoint, error) {
	s := checkpoint{Format: 1, PlanHash: planHash(p), Identities: map[string]string{}, Passwords: map[string]string{}, ClusterID: cluster, Prefix: p.Prefix, Roles: map[string]uint32{}, Databases: map[string]uint32{}}
	var err error
	if s.ID, err = randomID(); err != nil {
		return s, err
	}
	for _, role := range roles {
		if s.Identities[role], err = randomID(); err != nil {
			return s, err
		}
		if domain(role) != "" {
			if s.Passwords[role], err = randomID(); err != nil {
				return s, err
			}
		}
	}
	return s, nil
}
func (s checkpoint) validate(p plan, cluster string) error {
	if s.Format != 1 || s.PlanHash != planHash(p) || len(s.Identities) != 12 || len(s.Passwords) != 10 || s.ClusterID != cluster || s.Prefix != p.Prefix || s.Roles == nil || s.Databases == nil {
		return errors.New("checkpoint scope differs")
	}
	wantRoles := map[string]bool{p.Prefix + "_owner": true}
	for _, role := range roles {
		if domain(role) != "" {
			wantRoles[p.Prefix+"_"+role] = true
		}
	}
	wantDatabases := map[string]bool{}
	for _, d := range domains {
		wantDatabases[p.Prefix+"_"+d] = true
	}
	for name, oid := range s.Roles {
		if !wantRoles[name] || (s.Complete && oid == 0) {
			return errors.New("unknown retained role intent")
		}
	}
	for name, oid := range s.Databases {
		if !wantDatabases[name] || (s.Complete && oid == 0) {
			return errors.New("unknown retained database intent")
		}
	}
	if s.Complete && (len(s.Roles) != 11 || len(s.Databases) != 8) {
		return errors.New("completed object map is incomplete")
	}
	seen := map[string]bool{p.AdminToken: true, p.BusinessToken: true}
	for _, value := range append([]string{s.ID}, mapValues(s.Identities, s.Passwords)...) {
		b, err := hex.DecodeString(value)
		if err != nil || len(b) != 32 || seen[value] {
			return errors.New("invalid retained identity")
		}
		seen[value] = true
	}
	for _, role := range roles {
		if s.Identities[role] == "" || (domain(role) != "" && s.Passwords[role] == "") {
			return errors.New("incomplete retained identities")
		}
	}
	return nil
}
func mapValues(maps ...map[string]string) []string {
	var result []string
	for _, m := range maps {
		for _, v := range m {
			result = append(result, v)
		}
	}
	return result
}
func applicationURL(p plan, s checkpoint, role string) string {
	u, _ := url.Parse(p.AdminDatabaseURL)
	u.User = url.UserPassword(p.Prefix+"_"+role, s.Passwords[role])
	u.Path = "/" + p.Prefix + "_" + domain(role)
	u.RawPath = ""
	q := u.Query()
	schema := "public"
	if d := domain(role); d == "knowledge" || d == "toolhub" || d == "sources" {
		schema = d
	}
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	return u.String()
}
func configurations(p plan, s checkpoint) (map[string]map[string]string, []target) {
	peers := map[string]string{}
	for role, token := range s.Identities {
		peers[role] = hash([]byte(token))
	}
	encoded, _ := json.Marshal(peers)
	configs := map[string]map[string]string{}
	for _, role := range roles {
		c := map[string]string{"SERVICE_TOKEN": s.Identities[role], "SERVICE_PEERS": string(encoded), "DEV_LOCAL": "0", "DB_MAX_CONNS": "3", "GOMEMLIMIT": "96MiB"}
		for _, peer := range []string{"registry", "runtime", "toolhub", "knowledge", "storage", "sandbox", "sources"} {
			c[strings.ToUpper(peer)+"_URL"] = strings.TrimRight(p.Endpoints[peer], "/")
		}
		if domain(role) != "" {
			c["DATABASE_URL"] = applicationURL(p, s, role)
		}
		switch role {
		case "registry":
			c["MASTER_KEY"] = p.MasterKey
		case "control":
			c["ADMIN_TOKEN"] = p.AdminToken
		case "futures":
			c["BUSINESS_TOKEN"] = p.BusinessToken
		case "worker":
			c["GOMEMLIMIT"] = "192MiB"
		}
		for k, v := range p.Options[role] {
			c[k] = v
		}
		configs[role] = c
	}
	var targets []target
	for _, d := range domains {
		t := target{Owner: d, Database: p.Prefix + "_" + d, Roles: map[string]string{}}
		for _, role := range roles {
			if domain(role) == d {
				t.Roles[role] = p.Prefix + "_" + role
			}
		}
		targets = append(targets, t)
	}
	return configs, targets
}
