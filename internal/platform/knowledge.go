package platform

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

type KnowledgeBase struct {
	Name        string      `json:"name"`
	Description string      `json:"description"`
	Engine      string      `json:"engine"`
	Endpoint    string      `json:"endpoint"`
	KeyEnv      string      `json:"key_env"`
	Embedding   ModelConfig `json:"embedding"`
	Dimensions  int         `json:"dimensions"`
	QueryPrefix string      `json:"query_prefix"`
	ChunkSize   int         `json:"chunk_size"`
}

func (k *KnowledgeBase) Validate() error {
	k.Endpoint = strings.TrimRight(strings.TrimSpace(k.Endpoint), "/")
	if k.Name == "" || !Has([]string{"local", "milvus", "lightrag"}, k.Engine) {
		return errors.New("knowledge base needs a name and supported retrieval engine")
	}
	if k.ChunkSize == 0 {
		k.ChunkSize = 900
	}
	if k.ChunkSize < 200 || k.ChunkSize > 2000 {
		return errors.New("chunk size must be 200–2000 characters")
	}
	if k.Engine != "local" {
		if e := validateEndpoint(k.Endpoint); e != nil {
			return e
		}
	}
	if k.Engine == "milvus" {
		if e := validateEndpoint(k.Embedding.BaseURL); e != nil {
			return e
		}
		if k.Embedding.Model == "" || k.Dimensions < 1 || k.Dimensions > 8192 {
			return errors.New("embedding model and dimensions required")
		}
	}
	return nil
}

type KnowledgeFile struct {
	ID         string        `json:"id"`
	KBID       string        `json:"kb_id"`
	Revision   int           `json:"kb_revision"`
	DocumentID string        `json:"document_id"`
	Hash       string        `json:"artifact_hash"`
	Name       string        `json:"name"`
	Status     string        `json:"status"`
	Error      string        `json:"error"`
	TrackID    string        `json:"track_id"`
	Config     KnowledgeBase `json:"config"`
}
type Retrieval struct {
	Engine string           `json:"engine"`
	Hits   []map[string]any `json:"hits"`
	Graph  json.RawMessage  `json:"graph,omitempty"`
}

func providerJSON(ctx context.Context, method, endpoint, key, header string, body any) ([]byte, error) {
	if e := validateEndpoint(endpoint); e != nil {
		return nil, e
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(JSON(body))
	}
	req, e := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if e != nil {
		return nil, e
	}
	req.Header.Set("Content-Type", "application/json")
	if key != "" {
		if header == "X-API-Key" {
			req.Header.Set(header, key)
		} else {
			req.Header.Set("Authorization", "Bearer "+key)
		}
	}
	resp, e := externalHTTP.Do(req)
	if e != nil {
		return nil, e
	}
	defer resp.Body.Close()
	b, e := io.ReadAll(io.LimitReader(resp.Body, 4<<20+1))
	if e != nil {
		return nil, e
	}
	if len(b) > 4<<20 {
		return nil, errors.New("provider response exceeds 4 MiB")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("provider HTTP %d", resp.StatusCode)
	}
	if !json.Valid(b) {
		return nil, errors.New("provider returned invalid JSON")
	}
	return b, nil
}
func extractUpload(name string, b []byte) (string, error) {
	if len(b) == 0 || len(b) > 1<<20 {
		return "", errors.New("file must contain 1 byte to 1 MiB")
	}
	switch strings.ToLower(filepath.Ext(name)) {
	case ".txt", ".md", ".csv", ".json":
		if !utf8.Valid(b) || bytes.IndexByte(b, 0) >= 0 {
			return "", errors.New("text file must use UTF-8")
		}
		return string(b), nil
	case ".docx":
		z, e := zip.NewReader(bytes.NewReader(b), int64(len(b)))
		if e != nil {
			return "", e
		}
		for _, f := range z.File {
			if f.Name == "word/document.xml" {
				if f.UncompressedSize64 > 4<<20 {
					return "", errors.New("DOCX text exceeds extraction limit")
				}
				r, e := f.Open()
				if e != nil {
					return "", e
				}
				defer r.Close()
				decoder := xml.NewDecoder(io.LimitReader(r, 4<<20))
				var out strings.Builder
				inText := false
				for {
					token, e := decoder.Token()
					if e == io.EOF {
						break
					}
					if e != nil {
						return "", e
					}
					switch v := token.(type) {
					case xml.StartElement:
						if v.Name.Local == "t" {
							inText = true
						}
					case xml.EndElement:
						if v.Name.Local == "t" {
							inText = false
						}
						if v.Name.Local == "p" {
							out.WriteByte('\n')
						}
					case xml.CharData:
						if inText {
							out.Write(v)
						}
					}
				}
				return out.String(), nil
			}
		}
		return "", errors.New("DOCX has no main document")
	default:
		return "", errors.New("supported files: UTF-8 TXT, Markdown, CSV, JSON and DOCX text; PDF/OCR needs an external parser")
	}
}
func chunks(text string, size int) []string {
	chars := []rune(text)
	out := []string{}
	overlap := min(100, size/5)
	for start := 0; start < len(chars); {
		end := min(start+size, len(chars))
		out = append(out, string(chars[start:end]))
		if end == len(chars) {
			break
		}
		start = end - overlap
	}
	return out
}
func (s *Store) UploadKnowledge(ctx context.Context, ref Ref, name, source string, body []byte) (KnowledgeFile, error) {
	var kb KnowledgeBase
	f := KnowledgeFile{}
	if e := s.Resource(ctx, "knowledge", ref, &kb); e != nil {
		return f, e
	}
	if e := kb.Validate(); e != nil {
		return f, e
	}
	content, e := extractUpload(name, body)
	if e != nil {
		return f, e
	}
	if len(content) > 1000000 {
		return f, errors.New("extracted document exceeds 1 MB")
	}
	if strings.TrimSpace(source) == "" {
		source = "upload:" + name
	}
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return f, e
	}
	defer tx.Rollback(ctx)
	hash := Hash(body)
	f = KnowledgeFile{ID: ID(), KBID: ref.ID, Revision: ref.Revision, Name: name, Hash: hash, Config: kb, Status: "queued"}
	// Serializes duplicate uploads before creating documents or retention roots.
	if _, e = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", fmt.Sprint(ref.ID, ref.Revision, hash)); e != nil {
		return f, e
	}
	var existing string
	e = tx.QueryRow(ctx, "SELECT id FROM knowledge_files WHERE kb_id=$1 AND kb_revision=$2 AND artifact_hash=$3", ref.ID, ref.Revision, hash).Scan(&existing)
	if e == nil {
		_ = tx.Rollback(ctx)
		return s.KnowledgeFile(ctx, existing)
	}
	if !errors.Is(e, pgx.ErrNoRows) {
		return f, e
	}
	if _, e = putArtifact(ctx, tx, body, "application/octet-stream", "knowledge:"+f.ID); e != nil {
		return f, e
	}
	d, e := putDocument(ctx, tx, Document{Kind: "evidence", Title: name, Content: content, Source: source, Scope: "knowledge:" + ref.ID, Metadata: map[string]any{"original_hash": hash, "kb_revision": ref.Revision}})
	if e != nil {
		return f, e
	}
	f.DocumentID = d.ID
	if kb.Engine == "local" {
		f.Status = "ready"
	}
	if _, e = tx.Exec(ctx, "INSERT INTO knowledge_files(id,kb_id,kb_revision,document_id,artifact_hash,name,status,config) VALUES($1,$2,$3,$4,$5,$6,$7,$8)", f.ID, ref.ID, ref.Revision, d.ID, hash, name, f.Status, JSON(kb)); e != nil {
		return f, e
	}
	for i, text := range chunks(content, kb.ChunkSize) {
		if _, e = tx.Exec(ctx, "INSERT INTO knowledge_chunks(id,file_id,ordinal,content) VALUES($1,$2,$3,$4)", Hash([]byte(fmt.Sprint(f.ID, ":", i))), f.ID, i, text); e != nil {
			return f, e
		}
	}
	return f, tx.Commit(ctx)
}
func (s *Store) KnowledgeFile(ctx context.Context, id string) (KnowledgeFile, error) {
	var f KnowledgeFile
	var cfg []byte
	e := s.DB.QueryRow(ctx, "SELECT id,kb_id,kb_revision,document_id,artifact_hash,name,status,error,track_id,config FROM knowledge_files WHERE id=$1", id).Scan(&f.ID, &f.KBID, &f.Revision, &f.DocumentID, &f.Hash, &f.Name, &f.Status, &f.Error, &f.TrackID, &cfg)
	if e == nil {
		e = json.Unmarshal(cfg, &f.Config)
	}
	return f, e
}
func (s *Store) Embed(ctx context.Context, kb KnowledgeBase, text []string, query bool) ([][]float64, error) {
	if query && kb.QueryPrefix != "" {
		for i := range text {
			text[i] = kb.QueryPrefix + text[i]
		}
	}
	key, e := s.Secret(ctx, kb.Embedding.KeyEnv)
	if e != nil {
		return nil, e
	}
	b, e := providerJSON(ctx, "POST", strings.TrimRight(kb.Embedding.BaseURL, "/")+"/embeddings", key, "", map[string]any{"model": kb.Embedding.Model, "input": text, "encoding_format": "float"})
	if e != nil {
		return nil, e
	}
	var response struct {
		Data []struct {
			Index     int       `json:"index"`
			Embedding []float64 `json:"embedding"`
		} `json:"data"`
	}
	if e = json.Unmarshal(b, &response); e != nil {
		return nil, e
	}
	if len(response.Data) != len(text) {
		return nil, errors.New("embedding count mismatch")
	}
	out := make([][]float64, len(text))
	for _, item := range response.Data {
		if item.Index < 0 || item.Index >= len(out) || out[item.Index] != nil || len(item.Embedding) != kb.Dimensions {
			return nil, errors.New("embedding index/dimension mismatch")
		}
		out[item.Index] = item.Embedding
	}
	return out, nil
}
func collection(ref Ref) string { return "kb_" + Hash(JSON(ref))[:24] }
func (s *Store) milvus(ctx context.Context, kb KnowledgeBase, path string, body any) ([]byte, error) {
	key, e := s.Secret(ctx, kb.KeyEnv)
	if e != nil {
		return nil, e
	}
	b, e := providerJSON(ctx, "POST", strings.TrimRight(kb.Endpoint, "/")+"/v2/vectordb/"+path, key, "", body)
	if e != nil {
		return nil, e
	}
	var result struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	}
	if e = json.Unmarshal(b, &result); e != nil {
		return nil, e
	}
	if result.Code != 0 {
		return nil, fmt.Errorf("Milvus error %d: %s", result.Code, truncateUTF8(result.Message, 300))
	}
	return b, nil
}
func (s *Store) Retrieve(ctx context.Context, ref Ref, kb KnowledgeBase, query string) (Retrieval, error) {
	result := Retrieval{Engine: kb.Engine, Hits: []map[string]any{}}
	if strings.TrimSpace(query) == "" || len(query) > 4000 {
		return result, errors.New("query must be 1–4000 bytes")
	}
	if kb.Engine == "local" {
		terms := strings.Fields(query)
		if len(terms) == 0 {
			return result, nil
		}
		rows, e := s.DB.Query(ctx, `SELECT c.id,c.content,d.source,d.id,f.name FROM knowledge_chunks c JOIN knowledge_files f ON f.id=c.file_id JOIN documents d ON d.id=f.document_id WHERE f.kb_id=$1 AND f.kb_revision=$2 AND f.status='ready' AND position(lower($3) in lower(c.content))>0 ORDER BY f.created_at DESC,c.ordinal LIMIT 8`, ref.ID, ref.Revision, query)
		if e != nil {
			return result, e
		}
		defer rows.Close()
		for rows.Next() {
			var id, content, source, document, name string
			if e = rows.Scan(&id, &content, &source, &document, &name); e != nil {
				return result, e
			}
			result.Hits = append(result.Hits, map[string]any{"chunk_id": id, "content": content, "source": source, "document_id": document, "title": name})
		}
		return result, rows.Err()
	}
	if kb.Engine == "lightrag" {
		key, e := s.Secret(ctx, kb.KeyEnv)
		if e != nil {
			return result, e
		}
		b, e := providerJSON(ctx, "POST", strings.TrimRight(kb.Endpoint, "/")+"/query/data", key, "X-API-Key", map[string]any{"query": query, "mode": "mix", "top_k": 10, "chunk_top_k": 8})
		if e != nil {
			return result, e
		}
		var response struct {
			Status string          `json:"status"`
			Data   json.RawMessage `json:"data"`
		}
		if e = json.Unmarshal(b, &response); e != nil {
			return result, e
		}
		if response.Status != "success" {
			return result, errors.New("LightRAG query failed")
		}
		result.Graph = response.Data
		return result, nil
	}
	vectors, e := s.Embed(ctx, kb, []string{query}, true)
	if e != nil {
		return result, e
	}
	b, e := s.milvus(ctx, kb, "entities/search", map[string]any{"collectionName": collection(ref), "data": vectors, "annsField": "vector", "limit": 8, "outputFields": []string{"chunk_id"}, "consistencyLevel": "Strong"})
	if e != nil {
		return result, e
	}
	var response struct {
		Data []struct {
			ID       string  `json:"id"`
			Distance float64 `json:"distance"`
		} `json:"data"`
	}
	if e = json.Unmarshal(b, &response); e != nil {
		return result, e
	}
	for _, hit := range response.Data {
		var text, source, doc, name string
		e = s.DB.QueryRow(ctx, `SELECT c.content,d.source,d.id,f.name FROM knowledge_chunks c JOIN knowledge_files f ON f.id=c.file_id JOIN documents d ON d.id=f.document_id WHERE c.id=$1 AND f.kb_id=$2 AND f.kb_revision=$3 AND f.status='ready'`, hit.ID, ref.ID, ref.Revision).Scan(&text, &source, &doc, &name)
		if errors.Is(e, pgx.ErrNoRows) {
			continue
		}
		if e != nil {
			return result, e
		}
		result.Hits = append(result.Hits, map[string]any{"chunk_id": hit.ID, "content": text, "source": source, "document_id": doc, "title": name, "score": hit.Distance})
	}
	return result, nil
}
func (s *Server) knowledgeRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/files", wrap(func(w http.ResponseWriter, r *http.Request) error {
		rows, e := s.Store.DB.Query(r.Context(), "SELECT id FROM knowledge_files WHERE kb_id=$1 AND kb_revision=$2 ORDER BY created_at DESC LIMIT 100", r.URL.Query().Get("id"), r.URL.Query().Get("revision"))
		if e != nil {
			return e
		}
		ids := []string{}
		for rows.Next() {
			var id string
			if e = rows.Scan(&id); e != nil {
				rows.Close()
				return e
			}
			ids = append(ids, id)
		}
		e = rows.Err()
		rows.Close()
		if e != nil {
			return e
		}
		list := []KnowledgeFile{}
		for _, id := range ids {
			f, e := s.Store.KnowledgeFile(r.Context(), id)
			if e != nil {
				return e
			}
			list = append(list, f)
		}
		jsonResponse(w, 200, list)
		return nil
	}))
	mux.HandleFunc("POST /v1/upload", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			Knowledge Ref    `json:"knowledge"`
			Name      string `json:"name"`
			Source    string `json:"source"`
			Content   []byte `json:"content"`
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		f, e := s.Store.UploadKnowledge(r.Context(), in.Knowledge, in.Name, in.Source, in.Content)
		if e != nil {
			return e
		}
		jsonResponse(w, 201, f)
		return nil
	}))
	mux.HandleFunc("POST /v1/query", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			Knowledge Ref    `json:"knowledge"`
			Query     string `json:"query"`
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		var kb KnowledgeBase
		if e := s.Store.Resource(r.Context(), "knowledge", in.Knowledge, &kb); e != nil {
			return e
		}
		v, e := s.Store.Retrieve(r.Context(), in.Knowledge, kb, in.Query)
		if e != nil {
			return e
		}
		jsonResponse(w, 200, v)
		return nil
	}))
	mux.HandleFunc("POST /v1/retrieve", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			RunID string `json:"run_id"`
			KBID  string `json:"kb_id"`
			Query string `json:"query"`
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		run, e := s.Store.Run(r.Context(), in.RunID)
		if e != nil {
			return e
		}
		kb, ok := run.Snapshot.Knowledge[in.KBID]
		if !ok {
			return errors.New("knowledge base not bound to agent")
		}
		var ref Ref
		for _, candidate := range run.Snapshot.Agent.Knowledge {
			if candidate.ID == in.KBID {
				ref = candidate
			}
		}
		v, e := s.Store.Retrieve(r.Context(), ref, kb, in.Query)
		if e != nil {
			return e
		}
		jsonResponse(w, 200, v)
		return nil
	}))
	mux.HandleFunc("POST /v1/files/{id}/retry", wrap(func(w http.ResponseWriter, r *http.Request) error {
		tag, e := s.Store.DB.Exec(r.Context(), "UPDATE knowledge_files SET status='queued',error='',updated_at=now() WHERE id=$1 AND status='failed' AND config->>'engine'='milvus'", r.PathValue("id"))
		if e != nil {
			return e
		}
		if tag.RowsAffected() != 1 {
			return errors.New("only failed Milvus upserts can be retried; LightRAG needs external receipt reconciliation")
		}
		jsonResponse(w, 200, map[string]bool{"queued": true})
		return nil
	}))
	mux.HandleFunc("POST /v1/files/{id}/reconcile", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			TrackID  string `json:"track_id"`
			Evidence string `json:"evidence"`
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		if !safeName.MatchString(in.TrackID) || in.Evidence == "" {
			return errors.New("verified track id and evidence required")
		}
		tag, e := s.Store.DB.Exec(r.Context(), "UPDATE knowledge_files SET track_id=$2,status='external_pending',receipt=$3,error='',updated_at=now() WHERE id=$1 AND status='unknown'", r.PathValue("id"), in.TrackID, JSON(in))
		if e != nil {
			return e
		}
		if tag.RowsAffected() != 1 {
			return errors.New("unknown import not found")
		}
		jsonResponse(w, 200, map[string]bool{"tracking": true})
		return nil
	}))
}
func (s *Store) RunIndexer(ctx context.Context) error {
	tick := time.NewTicker(3 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
			rows, e := s.DB.Query(ctx, "SELECT id FROM knowledge_files WHERE status IN('queued','running','external_pending') ORDER BY updated_at LIMIT 10")
			if e != nil {
				continue
			}
			ids := []string{}
			for rows.Next() {
				var id string
				if rows.Scan(&id) == nil {
					ids = append(ids, id)
				}
			}
			rows.Close()
			for _, id := range ids {
				_ = s.indexFile(ctx, id)
			}
		}
	}
}
func (s *Store) indexFile(ctx context.Context, id string) error {
	conn, e := s.DB.Acquire(ctx)
	if e != nil {
		return e
	}
	defer conn.Release()
	var locked bool
	if e = conn.QueryRow(ctx, "SELECT pg_try_advisory_lock(hashtextextended($1,42))", id).Scan(&locked); e != nil {
		return e
	}
	if !locked {
		return nil
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if _, err := conn.Exec(cleanup, "SELECT pg_advisory_unlock(hashtextextended($1,42))", id); err != nil {
			// A pooled session must never retain this file's advisory lock.
			_ = conn.Conn().Close(cleanup)
		}
	}()
	f, e := s.KnowledgeFile(ctx, id)
	if e != nil {
		return e
	}
	if !Has([]string{"queued", "running", "external_pending"}, f.Status) {
		return nil
	}
	if f.Status == "running" && f.Config.Engine == "lightrag" {
		_, e = s.DB.Exec(ctx, "UPDATE knowledge_files SET status='unknown',error='Upload interrupted before receipt; verify LightRAG track id.',updated_at=now() WHERE id=$1", id)
		return e
	}
	if f.Status == "external_pending" {
		key, e := s.Secret(ctx, f.Config.KeyEnv)
		if e != nil {
			return e
		}
		b, e := providerJSON(ctx, "GET", strings.TrimRight(f.Config.Endpoint, "/")+"/documents/track_status/"+url.PathEscape(f.TrackID), key, "X-API-Key", nil)
		if e != nil {
			return e
		}
		var tracked struct {
			Documents []struct {
				Status string `json:"status"`
			} `json:"documents"`
		}
		if e = json.Unmarshal(b, &tracked); e != nil {
			return e
		}
		status := "ready"
		if len(tracked.Documents) == 0 {
			status = "external_pending"
		}
		for _, d := range tracked.Documents {
			if d.Status == "failed" {
				status = "failed"
				break
			}
			if d.Status != "processed" {
				status = "external_pending"
			}
		}
		_, e = s.DB.Exec(ctx, "UPDATE knowledge_files SET status=$2,receipt=$3,updated_at=now() WHERE id=$1", id, status, b)
		return e
	}
	if _, e = s.DB.Exec(ctx, "UPDATE knowledge_files SET status='running',updated_at=now() WHERE id=$1", id); e != nil {
		return e
	}
	finish := func(status string, receipt []byte, err error) error {
		msg := ""
		if err != nil {
			msg = err.Error()
		}
		if receipt == nil {
			receipt = JSON(nil)
		}
		_, e := s.DB.Exec(ctx, "UPDATE knowledge_files SET status=$2,receipt=$3,error=$4,updated_at=now() WHERE id=$1", id, status, receipt, msg)
		return e
	}
	if f.Config.Engine == "lightrag" {
		key, e := s.Secret(ctx, f.Config.KeyEnv)
		if e != nil {
			return finish("failed", nil, e)
		}
		var text string
		if e = s.DB.QueryRow(ctx, "SELECT content FROM documents WHERE id=$1", f.DocumentID).Scan(&text); e != nil {
			return e
		}
		b, e := providerJSON(ctx, "POST", strings.TrimRight(f.Config.Endpoint, "/")+"/documents/text", key, "X-API-Key", map[string]string{"text": text, "file_source": f.ID + "-" + filepath.Base(f.Name)})
		if e != nil {
			return finish("unknown", nil, e)
		}
		var receipt struct {
			TrackID string `json:"track_id"`
		}
		if e = json.Unmarshal(b, &receipt); e != nil || receipt.TrackID == "" {
			return finish("unknown", b, errors.New("LightRAG accepted response lacks track id"))
		}
		_, e = s.DB.Exec(ctx, "UPDATE knowledge_files SET status='external_pending',track_id=$2,receipt=$3,updated_at=now() WHERE id=$1", id, receipt.TrackID, b)
		return e
	}
	ref := Ref{f.KBID, f.Revision}
	name := collection(ref)
	b, e := s.milvus(ctx, f.Config, "collections/has", map[string]any{"collectionName": name})
	if e != nil {
		return finish("failed", nil, e)
	}
	var has struct {
		Data struct {
			Has bool `json:"has"`
		} `json:"data"`
	}
	if e = json.Unmarshal(b, &has); e != nil {
		return finish("failed", nil, e)
	}
	if !has.Data.Has {
		_, e = s.milvus(ctx, f.Config, "collections/create", map[string]any{"collectionName": name, "dimension": f.Config.Dimensions, "metricType": "COSINE", "idType": "VarChar", "primaryFieldName": "id", "vectorFieldName": "vector", "autoId": false, "params": map[string]any{"max_length": 64, "enableDynamicField": true}})
		if e != nil {
			return finish("failed", nil, e)
		}
	}
	rows, e := s.DB.Query(ctx, "SELECT id,content FROM knowledge_chunks WHERE file_id=$1 ORDER BY ordinal", id)
	if e != nil {
		return e
	}
	ids, texts := []string{}, []string{}
	for rows.Next() {
		var chunk, text string
		if e = rows.Scan(&chunk, &text); e != nil {
			rows.Close()
			return e
		}
		ids = append(ids, chunk)
		texts = append(texts, text)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for start := 0; start < len(texts); start += 16 {
		end := min(start+16, len(texts))
		vectors, e := s.Embed(ctx, f.Config, texts[start:end], false)
		if e != nil {
			return finish("failed", nil, e)
		}
		data := []any{}
		for i, v := range vectors {
			data = append(data, map[string]any{"id": ids[start+i], "chunk_id": ids[start+i], "vector": v})
		}
		b, e = s.milvus(ctx, f.Config, "entities/upsert", map[string]any{"collectionName": name, "data": data})
		if e != nil {
			return finish("failed", nil, e)
		}
	}
	return finish("ready", b, nil)
}
