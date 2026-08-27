package controlplane_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"go_core/overlay/controlplane"
	"go_core/overlay/fault"
)

func TestGetConfigRejectsUnknownFieldsAndTrailingJSON(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{name: "unknown field", body: `{"schema_version":1,"unexpected":true}`},
		{name: "nested secret field", body: `{"nodes":[{"private_key":"secret"}]}`},
		{name: "trailing JSON", body: `{} {}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				writer.Header().Set("Content-Type", "application/json")
				_, _ = writer.Write([]byte(test.body))
			}))
			defer server.Close()
			client, err := controlplane.New(server.URL, "token", server.Client())
			if err != nil {
				t.Fatalf("create client: %v", err)
			}

			_, err = client.GetConfig(t.Context(), controlplane.ConfigRequest{DeviceID: "dev_laptop"})
			if fault.Code(err) != fault.CodeInvalidResponse {
				t.Fatalf("error code = %q, err=%v", fault.Code(err), err)
			}
		})
	}
}
