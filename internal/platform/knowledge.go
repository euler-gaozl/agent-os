package platform

import (
	"context"
	"github.com/euler-gaozl/agent-os/services/knowledge"
	"net/http"
)

func (s *Store) knowledgeStore() *knowledge.Store {
	return &knowledge.Store{DB: s.DB, ResourceReader: s, SecretReader: s, RunReader: s}
}
func (s *Store) UploadKnowledge(ctx context.Context, ref Ref, name, source string, b []byte) (KnowledgeFile, error) {
	return s.knowledgeStore().UploadKnowledge(ctx, ref, name, source, b)
}
func (s *Store) KnowledgeFile(ctx context.Context, id string) (KnowledgeFile, error) {
	return s.knowledgeStore().KnowledgeFile(ctx, id)
}
func (s *Store) Embed(ctx context.Context, kb KnowledgeBase, text []string, query bool) ([][]float64, error) {
	return s.knowledgeStore().Embed(ctx, kb, text, query)
}
func (s *Store) Retrieve(ctx context.Context, ref Ref, kb KnowledgeBase, q string) (Retrieval, error) {
	return s.knowledgeStore().Retrieve(ctx, ref, kb, q)
}
func (s *Store) RunIndexer(ctx context.Context) error { return s.knowledgeStore().RunIndexer(ctx) }
func (s *Store) indexFile(ctx context.Context, id string) error {
	return s.knowledgeStore().IndexFile(ctx, id)
}
func (s *Server) knowledgeRoutes(mux *http.ServeMux) {
	(&knowledge.Server{Store: s.Store.knowledgeStore()}).Routes(mux)
}

var providerJSON = knowledge.ProviderJSON

func collection(ref Ref) string { return "kb_" + Hash(JSON(ref))[:24] }
