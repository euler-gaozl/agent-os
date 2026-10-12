package platform

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestDSHEvidencePastFourMiBRecallsOmittedSourceAfterProcessInterruption(t *testing.T) {
	setupDSH(t)
	s, _ := testStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	original, e := s.PutDocument(ctx, Document{Kind: "evidence", Title: "库存修订", Content: "受控验收：初值12吨已撤回，修订实绩17吨；下月20吨仅为计划。", Source: "fixture://OMITTED-SOURCE-492"})
	if e != nil {
		t.Fatal(e)
	}
	var ordinary, summaries, models, recallInvocations atomic.Int32
	var sourceMissing atomic.Bool
	tool := func(name string, args any) Message {
		return Message{Role: "assistant", ToolCalls: []ToolCall{{ID: fmt.Sprintf("fixture-%d", ordinary.Load()), Type: "function", Function: FunctionCall{Name: name, Arguments: string(JSON(args))}}}}
	}
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		var body struct {
			Messages []Message `json:"messages"`
		}
		if json.NewDecoder(req.Body).Decode(&body) != nil {
			w.WriteHeader(400)
			return
		}
		models.Add(1)
		if strings.Contains(body.Messages[len(body.Messages)-1].Content, "Create a concise continuity checkpoint") {
			summaries.Add(1)
			completion(w, Message{Role: "assistant", Content: "继续核对库存修订，原始来源标识和数值未保存在本摘要中。"})
			return
		}
		n := ordinary.Add(1)
		lastTool := func() string {
			for i := len(body.Messages) - 1; i >= 0; i-- {
				if body.Messages[i].Role == "tool" {
					return body.Messages[i].Content
				}
			}
			return ""
		}
		switch {
		case n == 1:
			completion(w, tool("knowledge_search", map[string]string{"query": "库存修订"}))
		case n >= 2 && n <= 8:
			m := tool("knowledge_search", map[string]string{"query": "filler-not-present"})
			m.Content = strings.Repeat("受控长记录abcdefghij；", 32000)
			completion(w, m)
		case n == 9:
			text := string(JSON(body.Messages))
			sourceMissing.Store(!strings.Contains(text, original.ID) && !strings.Contains(text, "OMITTED-SOURCE-492"))
			completion(w, tool("run_recall", map[string]string{"query": "库存修订"}))
		case n == 10:
			var list struct {
				Items []struct {
					ID string `json:"id"`
				} `json:"items"`
			}
			if json.Unmarshal([]byte(lastTool()), &list) != nil || len(list.Items) != 1 {
				t.Error("source receipt not rediscovered", lastTool())
				w.WriteHeader(500)
				return
			}
			completion(w, tool("run_recall", map[string]string{"operation_id": list.Items[0].ID}))
		case n == 11:
			var page struct {
				Content string `json:"content"`
			}
			var docs []Document
			if json.Unmarshal([]byte(lastTool()), &page) != nil || json.Unmarshal([]byte(page.Content), &docs) != nil || len(docs) != 1 || docs[0].ID != original.ID {
				t.Error("lost document ID not recovered")
				w.WriteHeader(500)
				return
			}
			completion(w, tool("document_read", map[string]string{"id": docs[0].ID}))
		case n == 12:
			if !strings.Contains(lastTool(), "修订实绩17吨") || !strings.Contains(lastTool(), original.Source) {
				t.Error("original source not read after recovery")
				w.WriteHeader(500)
				return
			}
			completion(w, Message{Role: "assistant", Content: "受控验收：修订实绩17吨，下月20吨是计划；原文已重新定位。"})
		default:
			t.Error("unexpected provider request", n)
			w.WriteHeader(500)
		}
	}))
	defer model.Close()
	firstCtx, kill := context.WithCancel(ctx)
	defer kill()
	killed := make(chan struct{})
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		var inv Invocation
		if json.NewDecoder(req.Body).Decode(&inv) != nil {
			w.WriteHeader(400)
			return
		}
		b, err := s.LocalTool(req.Context(), inv)
		if err != nil {
			t.Error("fixture tool failed", err)
			w.WriteHeader(500)
			return
		}
		if inv.Name == "run_recall" && recallInvocations.Add(1) == 1 {
			// The receipt is committed but the bridge reply is lost. Cancelling
			// the supervisor context kills its real DSH Node subprocess.
			kill()
			close(killed)
			<-req.Context().Done()
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(b)
	}))
	defer hub.Close()
	snap := basicSnapshot(model.URL)
	snap.Agent.Tools = append(snap.Agent.Tools, "run_recall", "artifact_read", "document_read")
	snap.Agent.ContextTokens = 8192
	snap.Agent.MaxSteps = 40
	id := submit(t, s, snap)
	r := claim(t, s, "first-attempt")
	worker := Worker{Store: s, Lease: 10 * time.Second, ToolHubURL: hub.URL, Token: testToken}
	worker.execute(firstCtx, r)
	select {
	case <-killed:
	default:
		failed, _ := s.Run(ctx, id)
		t.Fatal("interruption point not reached", failed.Status, failed.State.Error)
	}
	before := models.Load()
	beforeOrdinary, beforeSummaries := ordinary.Load(), summaries.Load()
	if !sourceMissing.Load() || summaries.Load() == 0 {
		t.Fatal("test did not actually lose source ID through DSH compaction")
	}
	if _, e = s.DB.Exec(ctx, "UPDATE runs SET lease_until=now()-interval '1 second' WHERE id=$1", id); e != nil {
		t.Fatal(e)
	}
	r = claim(t, s, "replacement-attempt")
	worker.execute(ctx, r)
	done, e := s.Run(ctx, id)
	if e != nil || done.Status != "completed" || !strings.Contains(done.State.Result, "修订实绩17吨") {
		t.Fatal("recovery failed", done.Status, done.State.Error, e)
	}
	if ordinary.Load() != beforeOrdinary+3 || models.Load() != before+3+summaries.Load()-beforeSummaries || recallInvocations.Load() != 2 {
		t.Fatal("replay repeated provider or committed recall", before, models.Load(), recallInvocations.Load())
	}
	var duplicateAttempts int
	if e = s.DB.QueryRow(ctx, `SELECT count(*) FROM (SELECT a.call_id FROM model_attempts a JOIN calls c ON c.id=a.call_id WHERE c.run_id=$1 GROUP BY a.call_id HAVING count(*)>1) repeated`, id).Scan(&duplicateAttempts); e != nil || duplicateAttempts != 0 {
		t.Fatal("cached model invocation was charged again", duplicateAttempts, e)
	}
	rows, e := s.DB.Query(ctx, "SELECT manifest_hash,batch IS NULL FROM harness_archives WHERE run_id=$1 ORDER BY seq", id)
	if e != nil {
		t.Fatal(e)
	}
	hashes := []string{}
	for rows.Next() {
		var hash string
		var cleared bool
		if e = rows.Scan(&hash, &cleared); e != nil || !cleared {
			rows.Close()
			t.Fatal("staging not retired", e)
		}
		hashes = append(hashes, hash)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		t.Fatal(e)
	}
	bytes, end := 0, 0
	previous := ""
	originalFound, compactFound := false, false
	for _, hash := range hashes {
		raw, a := readArchiveFixture(t, s, hash)
		if a.EventStart != end || a.Previous != previous {
			t.Fatal("archive chain discontinuity")
		}
		bytes += len(raw)
		end = a.EventEnd
		previous = hash
		originalFound = originalFound || strings.Contains(string(raw), original.Source)
		compactFound = compactFound || strings.Contains(string(raw), "compaction/end")
	}
	if bytes <= 4<<20 || !originalFound || !compactFound || previous != done.State.HarnessArtifact {
		t.Fatal("large history retention not proven", bytes, originalFound, compactFound)
	}
	var stored int64
	if e = s.DB.QueryRow(ctx, "SELECT COALESCE(sum(octet_length(body)),0) FROM artifacts").Scan(&stored); e != nil {
		t.Fatal(e)
	}
	if stored > int64(bytes)+int64(len(hashes))*4096 {
		t.Fatal("retention still duplicates growing prefixes", stored, bytes)
	}
	t.Logf("Retained %d event bytes in %d batches; %d compact calls; source omitted, real DSH process interrupted, source rediscovered and original reread; stored artifact bytes %d", bytes, len(hashes), summaries.Load(), stored)
}
