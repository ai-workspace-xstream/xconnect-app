package runtime

import (
	"context"

	"go_core/overlay/fault"
	"go_core/overlay/model"
)

type ApplyRequest struct {
	Config              model.Config
	WireGuardPrivateKey string
}

type ApplyResult struct {
	Revision  string
	CoreID    string
	AdapterID string
}

type Status struct {
	Available bool   `json:"available"`
	Applied   bool   `json:"applied"`
	Revision  string `json:"revision,omitempty"`
	CoreID    string `json:"core_id,omitempty"`
	AdapterID string `json:"adapter_id,omitempty"`
}

type Diagnostic struct {
	Code    string `json:"code"`
	Healthy bool   `json:"healthy"`
}

type Interface interface {
	Apply(context.Context, ApplyRequest) (ApplyResult, error)
	Status(context.Context) (Status, error)
	Diagnose(context.Context) ([]Diagnostic, error)
}

// Unavailable is the production-safe Batch 02 default. It prevents an
// enrollment-only CLI from acknowledging a config before a platform runtime
// has actually applied it.
type Unavailable struct {
	diagnostics []Diagnostic
}

func NewUnavailable() *Unavailable {
	return &Unavailable{diagnostics: []Diagnostic{{Code: "platform_runtime_available", Healthy: false}}}
}

// NewProtectedHostUnavailable represents a platform whose system networking
// must be supplied by a protected native host (for example Apple's Packet
// Tunnel extension), not by the external Linux command runtime.
func NewProtectedHostUnavailable() *Unavailable {
	return &Unavailable{diagnostics: []Diagnostic{
		{Code: "platform_runtime_available", Healthy: false},
		{Code: "protected_host_runtime_required", Healthy: true},
	}}
}

func (r *Unavailable) Apply(context.Context, ApplyRequest) (ApplyResult, error) {
	return ApplyResult{}, fault.New(fault.CodeRuntimeUnavailable, "apply runtime profile", nil)
}

func (r *Unavailable) Status(context.Context) (Status, error) {
	return Status{Available: false}, nil
}

func (r *Unavailable) Diagnose(context.Context) ([]Diagnostic, error) {
	return append([]Diagnostic(nil), r.diagnostics...), nil
}
