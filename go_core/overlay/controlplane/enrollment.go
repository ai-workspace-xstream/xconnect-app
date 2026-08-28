package controlplane

import (
	"context"
	"encoding/base64"
	"net/http"
	"net/netip"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"go_core/overlay/fault"
	"go_core/overlay/model"
	"go_core/overlay/signedconfig"
)

const maximumEnrollmentLifetime = time.Hour + time.Minute

var enrollmentDeviceIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,127}$`)

type JoinTokenExchangeRequest struct {
	JoinToken          string    `json:"join_token"`
	DeviceID           string    `json:"device_id"`
	Name               string    `json:"name,omitempty"`
	Platform           string    `json:"platform"`
	Hostname           string    `json:"hostname,omitempty"`
	WireGuardPublicKey string    `json:"wireguard_public_key"`
	Now                time.Time `json:"-"`
}

type JoinTokenExchangeResponse struct {
	EnrollmentToken string                    `json:"enrollment_token"`
	TokenType       string                    `json:"token_type"`
	ExpiresAt       time.Time                 `json:"expires_at"`
	Scope           []string                  `json:"scope"`
	Device          model.Device              `json:"device"`
	Network         model.Network             `json:"network"`
	SigningKeys     []signedconfig.SigningKey `json:"signing_keys"`
}

func (c *Client) ExchangeJoinToken(ctx context.Context, request JoinTokenExchangeRequest) (JoinTokenExchangeResponse, error) {
	if !validOpaqueSecret(request.JoinToken, "xjt_") || !enrollmentDeviceIDPattern.MatchString(request.DeviceID) || !validEnrollmentPlatform(request.Platform) || !validWireGuardPublicKey(request.WireGuardPublicKey) || len(request.Name) > 255 || len(request.Hostname) > 255 {
		return JoinTokenExchangeResponse{}, fault.New(fault.CodeInvalidInput, "exchange join invite", nil)
	}
	now := request.Now.UTC()
	if request.Now.IsZero() {
		now = time.Now().UTC()
	}
	_, headers, raw, err := c.doContractWithBearer(ctx, http.MethodPost, apiPrefixV1+"/join-tokens/exchange", nil, request, nil, "", contractErrorInviteExchange)
	if err != nil {
		return JoinTokenExchangeResponse{}, err
	}
	if headers.Get("Cache-Control") != "no-store" {
		return JoinTokenExchangeResponse{}, fault.New(fault.CodeInvalidResponse, "validate join exchange cache policy", nil)
	}
	response, err := strictContractDecode[JoinTokenExchangeResponse](raw)
	if err != nil {
		return JoinTokenExchangeResponse{}, fault.New(fault.CodeInvalidResponse, "decode join exchange", nil)
	}
	keys := signedconfig.SigningKeys{Keys: response.SigningKeys}
	if !validOpaqueSecret(response.EnrollmentToken, "xenr_") || response.TokenType != "Bearer" || !validEnrollmentScope(response.Scope) || response.ExpiresAt.Location() != time.UTC || !response.ExpiresAt.After(now) || response.ExpiresAt.Sub(now) > maximumEnrollmentLifetime || response.Device.ID != request.DeviceID || response.Device.Platform != request.Platform || response.Device.WireGuardPublicKey != request.WireGuardPublicKey || response.Device.NetworkID == "" || response.Network.ID != response.Device.NetworkID || !validIPv4HostPrefix(response.Device.WireGuardAddress) || !validIPv4Prefix(response.Network.CIDR) {
		return JoinTokenExchangeResponse{}, fault.New(fault.CodeInvalidResponse, "validate join exchange", nil)
	}
	if err := keys.Validate(); err != nil {
		return JoinTokenExchangeResponse{}, err
	}
	return response, nil
}

func (c *Client) GetEnrollmentSignedConfig(ctx context.Context, enrollmentToken string, request SignedConfigRequest) (signedconfig.Config, error) {
	if !validOpaqueSecret(enrollmentToken, "xenr_") {
		return signedconfig.Config{}, fault.New(fault.CodeEnrollmentUnavailable, "load enrollment session", nil)
	}
	query := url.Values{}
	query.Set("device_id", request.DeviceID)
	if request.NetworkID != "" {
		query.Set("network_id", request.NetworkID)
	}
	if request.NodeID != "" {
		query.Set("node_id", request.NodeID)
	}
	_, responseHeaders, raw, err := c.doContractWithBearer(ctx, http.MethodGet, apiPrefixV1+"/enrollment/signed-config", query, nil, nil, enrollmentToken, contractErrorEnrollment)
	if err != nil {
		return signedconfig.Config{}, err
	}
	if responseHeaders.Get("Cache-Control") != "private, no-store" || strings.TrimSpace(responseHeaders.Get("ETag")) == "" {
		return signedconfig.Config{}, fault.New(fault.CodeInvalidResponse, "validate enrollment signed-config cache headers", nil)
	}
	config, err := signedconfig.DecodeConfig(raw)
	if err != nil {
		return signedconfig.Config{}, err
	}
	config.ETag = responseHeaders.Get("ETag")
	return config, nil
}

func (c *Client) AckEnrollmentSignedConfig(ctx context.Context, enrollmentToken string, request SignedConfigAckRequest) (SignedConfigAckResponse, error) {
	if !validOpaqueSecret(enrollmentToken, "xenr_") || request.Generation == 0 || strings.TrimSpace(request.ConfigID) == "" || strings.TrimSpace(request.DeviceID) == "" || request.AppliedAt.IsZero() {
		return SignedConfigAckResponse{}, fault.New(fault.CodeInvalidInput, "ack enrollment signed config", nil)
	}
	payload := struct {
		ConfigID  string `json:"config_id"`
		DeviceID  string `json:"device_id"`
		AppliedAt string `json:"applied_at"`
	}{ConfigID: request.ConfigID, DeviceID: request.DeviceID, AppliedAt: request.AppliedAt.UTC().Truncate(time.Second).Format(time.RFC3339)}
	_, _, raw, err := c.doContractWithBearer(ctx, http.MethodPost, apiPrefixV1+"/enrollment/signed-config/"+strconv.FormatUint(request.Generation, 10)+"/ack", nil, payload, nil, enrollmentToken, contractErrorEnrollment)
	if err != nil {
		return SignedConfigAckResponse{}, err
	}
	response, err := strictContractDecode[SignedConfigAckResponse](raw)
	if err != nil || !response.Acked || response.Ack.Generation == 0 || strings.TrimSpace(response.Ack.ConfigID) == "" || strings.TrimSpace(response.Ack.DeviceID) == "" || response.Ack.AppliedAt.IsZero() || response.Ack.ReceivedAt.IsZero() {
		return SignedConfigAckResponse{}, fault.New(fault.CodeInvalidResponse, "decode enrollment signed-config acknowledgement", nil)
	}
	return response, nil
}

func validOpaqueSecret(value, prefix string) bool {
	if value != strings.TrimSpace(value) || !strings.HasPrefix(value, prefix) {
		return false
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(value, prefix))
	return err == nil && len(raw) == 32
}

func validWireGuardPublicKey(value string) bool {
	if value != strings.TrimSpace(value) {
		return false
	}
	raw, err := base64.StdEncoding.DecodeString(value)
	return err == nil && len(raw) == 32
}

func validEnrollmentScope(values []string) bool {
	if len(values) != 3 {
		return false
	}
	seen := map[string]bool{}
	for _, value := range values {
		if value != "overlay:config:read" && value != "overlay:config:ack" && value != "overlay:device:revoke" || seen[value] {
			return false
		}
		seen[value] = true
	}
	return seen["overlay:config:read"] && seen["overlay:config:ack"] && seen["overlay:device:revoke"]
}

func validIPv4Prefix(value string) bool {
	prefix, err := netip.ParsePrefix(value)
	return err == nil && prefix.Addr().Is4()
}

func validIPv4HostPrefix(value string) bool {
	prefix, err := netip.ParsePrefix(value)
	return err == nil && prefix.Addr().Is4() && prefix.Bits() == 32
}

func validEnrollmentPlatform(value string) bool {
	switch value {
	case "darwin", "windows", "linux", "ios", "android":
		return true
	default:
		return false
	}
}
