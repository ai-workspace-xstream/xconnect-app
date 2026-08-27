package fault

import "errors"

const (
	CodeInvalidInput            = "invalid_input"
	CodeStateIO                 = "state_io"
	CodeStateConflict           = "state_conflict"
	CodeAuthenticationFailed    = "authentication_failed"
	CodeAccessDenied            = "access_denied"
	CodeControlPlaneRejected    = "controlplane_rejected"
	CodeControlPlaneUnavailable = "controlplane_unavailable"
	CodeInvalidResponse         = "invalid_response"
	CodeInvalidConfig           = "invalid_config"
	CodeUnsupportedRuntimeCore  = "unsupported_runtime_core"
	CodeRuntimeUnavailable      = "runtime_unavailable"
	CodeRuntimeApplyFailed      = "runtime_apply_failed"
	CodeRuntimeStatusFailed     = "runtime_status_failed"
	CodeNotJoined               = "not_joined"
)

// Error exposes a stable code while deliberately withholding the wrapped
// cause from user-facing output. Callers may inspect the cause with errors.Is.
type Error struct {
	code  string
	op    string
	cause error
}

func New(code, operation string, cause error) *Error {
	return &Error{code: code, op: operation, cause: cause}
}

func (e *Error) Error() string {
	if e.op == "" {
		return e.code
	}
	return e.op + ": " + e.code
}

func (e *Error) Unwrap() error { return e.cause }

func (e *Error) Code() string { return e.code }

func Code(err error) string {
	var coded interface{ Code() string }
	if errors.As(err, &coded) {
		return coded.Code()
	}
	return CodeInvalidResponse
}
