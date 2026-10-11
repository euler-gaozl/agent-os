package platform

import (
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"net/http"
)

// Fixed service entry points avoid linking a role-selectable all-services server
// into each deployment. Shared execution transactions remain in this package.
func (s *Server) RuntimeHandler(c servicehttp.Config) http.Handler {
	return servicehttp.New(c, s.Store.DB.Ping, func(m *http.ServeMux) { s.runtimeRoutes(m); s.toolRoutes(m); s.applicationRoutes(m) })
}
func (s *Server) RegistryHandler(c servicehttp.Config) http.Handler {
	return servicehttp.New(c, s.Store.DB.Ping, func(m *http.ServeMux) { s.registryRoutes(m); s.publishedRoutes(m) })
}
func (s *Server) StorageHandler(c servicehttp.Config) http.Handler {
	return servicehttp.New(c, s.Store.DB.Ping, s.storageRoutes)
}
func (s *Server) SandboxHandler(c servicehttp.Config) http.Handler {
	return servicehttp.New(c, s.Store.DB.Ping, s.sandboxRoutes)
}
