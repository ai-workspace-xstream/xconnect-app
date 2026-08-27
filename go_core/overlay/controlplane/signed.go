package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"go_core/overlay/fault"
	"go_core/overlay/signedconfig"
)

type SigningKeysResponse struct {
	Keys        signedconfig.SigningKeys
	ETag        string
	NotModified bool
}

type SignedConfigRequest struct {
	DeviceID  string
	NetworkID string
	NodeID    string
}

type SignedConfigAckRequest struct {
	Generation uint64
	ConfigID   string
	DeviceID   string
	AppliedAt  time.Time
}

type SignedConfigAck struct {
	DeviceID   string                     `json:"device_id"`
	ConfigID   string                     `json:"config_id"`
	Generation uint64                     `json:"generation"`
	AppliedAt  signedconfig.CanonicalTime `json:"applied_at"`
	ReceivedAt signedconfig.CanonicalTime `json:"received_at"`
}

type SignedConfigAckResponse struct {
	Acked     bool            `json:"acked"`
	Duplicate bool            `json:"duplicate"`
	Ack       SignedConfigAck `json:"ack"`
}

func (c *Client) GetSigningKeys(ctx context.Context, etag string) (SigningKeysResponse, error) {
	headers := http.Header{}
	if strings.TrimSpace(etag) != "" {
		headers.Set("If-None-Match", strings.TrimSpace(etag))
	}
	status, responseHeaders, raw, err := c.doContract(ctx, http.MethodGet, apiPrefixV1+"/signing-keys", nil, nil, headers, true)
	if err != nil {
		return SigningKeysResponse{}, err
	}
	if status == http.StatusNotModified {
		return SigningKeysResponse{ETag: strings.TrimSpace(etag), NotModified: true}, nil
	}
	responseETag := strings.TrimSpace(responseHeaders.Get("ETag"))
	if responseETag == "" || responseHeaders.Get("Cache-Control") != "private, max-age=300" || !headerContainsToken(responseHeaders.Values("Vary"), "Authorization") {
		return SigningKeysResponse{}, fault.New(fault.CodeInvalidResponse, "validate signing-key cache headers", nil)
	}
	keys, err := signedconfig.DecodeSigningKeys(raw)
	if err != nil {
		return SigningKeysResponse{}, err
	}
	keys.ETag = responseETag
	return SigningKeysResponse{Keys: keys, ETag: responseETag}, nil
}

func (c *Client) GetSignedConfig(ctx context.Context, request SignedConfigRequest) (signedconfig.Config, error) {
	query := url.Values{}
	query.Set("device_id", request.DeviceID)
	if request.NetworkID != "" {
		query.Set("network_id", request.NetworkID)
	}
	if request.NodeID != "" {
		query.Set("node_id", request.NodeID)
	}
	_, responseHeaders, raw, err := c.doContract(ctx, http.MethodGet, apiPrefixV1+"/signed-config", query, nil, nil, true)
	if err != nil {
		return signedconfig.Config{}, err
	}
	if responseHeaders.Get("Cache-Control") != "private, no-store" || strings.TrimSpace(responseHeaders.Get("ETag")) == "" {
		return signedconfig.Config{}, fault.New(fault.CodeInvalidResponse, "validate signed-config cache headers", nil)
	}
	config, err := signedconfig.DecodeConfig(raw)
	if err != nil {
		return signedconfig.Config{}, err
	}
	config.ETag = responseHeaders.Get("ETag")
	return config, nil
}

func (c *Client) AckSignedConfig(ctx context.Context, request SignedConfigAckRequest) (SignedConfigAckResponse, error) {
	if request.Generation == 0 || strings.TrimSpace(request.ConfigID) == "" || strings.TrimSpace(request.DeviceID) == "" {
		return SignedConfigAckResponse{}, fault.New(fault.CodeInvalidInput, "ack signed config", nil)
	}
	payload := struct {
		ConfigID  string `json:"config_id"`
		DeviceID  string `json:"device_id"`
		AppliedAt string `json:"applied_at"`
	}{
		ConfigID:  request.ConfigID,
		DeviceID:  request.DeviceID,
		AppliedAt: request.AppliedAt.UTC().Truncate(time.Second).Format(time.RFC3339),
	}
	_, _, raw, err := c.doContract(ctx, http.MethodPost, apiPrefixV1+"/signed-config/"+strconv.FormatUint(request.Generation, 10)+"/ack", nil, payload, nil, false)
	if err != nil {
		return SignedConfigAckResponse{}, err
	}
	response, err := strictContractDecode[SignedConfigAckResponse](raw)
	if err != nil || !response.Acked || response.Ack.Generation == 0 || strings.TrimSpace(response.Ack.ConfigID) == "" || strings.TrimSpace(response.Ack.DeviceID) == "" {
		return SignedConfigAckResponse{}, fault.New(fault.CodeInvalidResponse, "decode signed-config acknowledgement", nil)
	}
	return response, nil
}

func (c *Client) doContract(ctx context.Context, method, path string, query url.Values, payload any, headers http.Header, signedCapability bool) (int, http.Header, []byte, error) {
	endpoint := *c.baseURL
	endpoint.Path = strings.TrimRight(endpoint.Path, "/") + path
	endpoint.RawQuery = query.Encode()
	var body io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return 0, nil, nil, fault.New(fault.CodeInvalidInput, "encode control plane request", err)
		}
		body = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, endpoint.String(), body)
	if err != nil {
		return 0, nil, nil, fault.New(fault.CodeInvalidInput, "create control plane request", err)
	}
	request.Header.Set("Accept", "application/json")
	if payload != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		request.Header.Set("Authorization", "Bearer "+c.token)
	}
	for key, values := range headers {
		for _, value := range values {
			request.Header.Add(key, value)
		}
	}
	response, err := c.httpClient.Do(request)
	if err != nil {
		return 0, nil, nil, fault.New(fault.CodeControlPlaneUnavailable, "request control plane", err)
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotModified && method == http.MethodGet {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		return response.StatusCode, response.Header.Clone(), nil, nil
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		if signedCapability && (response.StatusCode == http.StatusNotFound || response.StatusCode == http.StatusServiceUnavailable) {
			return response.StatusCode, nil, nil, fault.New(fault.CodeSignedConfigUnavailable, "signed config capability unavailable", nil)
		}
		return response.StatusCode, nil, nil, statusError(response.StatusCode)
	}
	mediaType, _, mediaErr := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if mediaErr != nil || mediaType != "application/json" && !strings.HasSuffix(strings.ToLower(mediaType), "+json") {
		return response.StatusCode, nil, nil, fault.New(fault.CodeInvalidResponse, "validate control plane content type", nil)
	}
	const maximumContractBody = 2 << 20
	raw, err := io.ReadAll(io.LimitReader(response.Body, maximumContractBody+1))
	if err != nil {
		return response.StatusCode, nil, nil, fault.New(fault.CodeInvalidResponse, "read control plane response", err)
	}
	if len(raw) > maximumContractBody {
		return response.StatusCode, nil, nil, fault.New(fault.CodeInvalidResponse, "reject oversized control plane response", nil)
	}
	return response.StatusCode, response.Header.Clone(), raw, nil
}

func strictContractDecode[T any](raw []byte) (T, error) {
	var result T
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return result, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return result, errors.New("response must contain one JSON value")
	}
	return result, nil
}

func headerContainsToken(values []string, expected string) bool {
	for _, value := range values {
		for _, token := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), expected) {
				return true
			}
		}
	}
	return false
}
