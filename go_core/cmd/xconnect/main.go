package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"go_core/overlay/controlplane"
	"go_core/overlay/fault"
	overlayruntime "go_core/overlay/runtime"
	"go_core/overlay/state"
	"go_core/overlay/usecase"
)

const defaultAccountsServer = "https://accounts.svc.plus"

type runtimeFactory func(stateDirectory string) overlayruntime.Interface

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stdout, os.Stderr, http.DefaultClient); err != nil {
		fmt.Fprintf(os.Stderr, "error[%s]: %v\n", fault.Code(err), err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer, httpClient *http.Client) error {
	return runWithRuntimeFactory(ctx, args, stdout, stderr, httpClient, func(string) overlayruntime.Interface {
		return overlayruntime.NewUnavailable()
	})
}

func runWithRuntimeFactory(ctx context.Context, args []string, stdout, stderr io.Writer, httpClient *http.Client, newRuntime runtimeFactory) error {
	if len(args) == 0 {
		return fault.New(fault.CodeInvalidInput, "expected join, status, or diagnose", nil)
	}
	switch args[0] {
	case "join":
		return runJoin(ctx, args[1:], stdout, stderr, httpClient, newRuntime)
	case "status":
		return runStatus(ctx, args[1:], stdout, stderr, newRuntime)
	case "diagnose":
		return runDiagnose(ctx, args[1:], stdout, stderr, newRuntime)
	default:
		return fault.New(fault.CodeInvalidInput, "unknown command", nil)
	}
}

func runJoin(ctx context.Context, args []string, stdout, stderr io.Writer, httpClient *http.Client, newRuntime runtimeFactory) error {
	args = moveLeadingJoinTargetAfterFlags(args)
	flags := flag.NewFlagSet("xconnect join", flag.ContinueOnError)
	flags.SetOutput(stderr)
	server := flags.String("server", defaultAccountsServer, "accounts service base URL")
	stateDirectory := flags.String("state-dir", defaultStateDirectory(), "local XConnect-One state directory")
	deviceID := flags.String("device-id", defaultDeviceID(), "stable local device ID")
	deviceName := flags.String("name", "", "device display name")
	networkID := flags.String("network-id", "", "requested overlay network ID")
	nodeID := flags.String("node-id", "", "preferred gateway node ID")
	tokenFile := flags.String("token-file", "", "path to a file containing the accounts access token")
	if err := flags.Parse(args); err != nil {
		return fault.New(fault.CodeInvalidInput, "parse join arguments", err)
	}
	if flags.NArg() > 1 {
		return fault.New(fault.CodeInvalidInput, "parse join target", nil)
	}
	targetValue := ""
	if flags.NArg() == 1 {
		targetValue = flags.Arg(0)
	}
	target, err := resolveJoinTarget(targetValue, *server)
	if err != nil {
		return err
	}
	if *networkID == "" {
		*networkID = target.NetworkID
	}
	if *nodeID == "" {
		*nodeID = target.NodeID
	}
	token, err := readToken(*tokenFile)
	if err != nil {
		return err
	}
	client, err := controlplane.New(target.Controller, token, httpClient)
	if err != nil {
		return err
	}
	hostname, _ := os.Hostname()
	store := state.NewStore(*stateDirectory)
	tunnelRuntime := newRuntime(*stateDirectory)
	result, err := usecase.NewJoiner(client, store, tunnelRuntime).Join(ctx, usecase.JoinRequest{
		Server:     target.Controller,
		DeviceID:   *deviceID,
		DeviceName: *deviceName,
		Platform:   runtime.GOOS,
		Hostname:   hostname,
		NetworkID:  *networkID,
		NodeID:     *nodeID,
	})
	if err != nil {
		return err
	}
	return writeJSON(stdout, result)
}

func moveLeadingJoinTargetAfterFlags(args []string) []string {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return args
	}
	reordered := append([]string(nil), args[1:]...)
	return append(reordered, args[0])
}

func runStatus(ctx context.Context, args []string, stdout, stderr io.Writer, newRuntime runtimeFactory) error {
	flags := flag.NewFlagSet("xconnect status", flag.ContinueOnError)
	flags.SetOutput(stderr)
	stateDirectory := flags.String("state-dir", defaultStateDirectory(), "local XConnect-One state directory")
	if err := flags.Parse(args); err != nil {
		return fault.New(fault.CodeInvalidInput, "parse status arguments", err)
	}
	store := state.NewStore(*stateDirectory)
	result, err := usecase.Status(ctx, store, newRuntime(*stateDirectory))
	if err != nil {
		return err
	}
	return writeJSON(stdout, result)
}

func runDiagnose(ctx context.Context, args []string, stdout, stderr io.Writer, newRuntime runtimeFactory) error {
	flags := flag.NewFlagSet("xconnect diagnose", flag.ContinueOnError)
	flags.SetOutput(stderr)
	stateDirectory := flags.String("state-dir", defaultStateDirectory(), "local XConnect-One state directory")
	if err := flags.Parse(args); err != nil {
		return fault.New(fault.CodeInvalidInput, "parse diagnose arguments", err)
	}
	store := state.NewStore(*stateDirectory)
	result, err := usecase.Diagnose(ctx, store, newRuntime(*stateDirectory))
	if err != nil {
		return err
	}
	return writeJSON(stdout, result)
}

func readToken(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return strings.TrimSpace(os.Getenv("XCONNECT_TOKEN")), nil
	}
	file, err := os.Open(path)
	if err != nil {
		return "", fault.New(fault.CodeAuthenticationFailed, "read access token", err)
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, 1<<20))
	if err != nil {
		return "", fault.New(fault.CodeAuthenticationFailed, "read access token", err)
	}
	return strings.TrimSpace(string(raw)), nil
}

type joinTarget struct {
	Controller string
	NetworkID  string
	NodeID     string
}

func resolveJoinTarget(value, fallbackController string) (joinTarget, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return joinTarget{Controller: strings.TrimRight(strings.TrimSpace(fallbackController), "/")}, nil
	}
	parsed, err := url.Parse(value)
	if err != nil {
		return joinTarget{}, fault.New(fault.CodeInvalidInput, "parse join target", err)
	}
	query := parsed.Query()
	for _, sensitiveKey := range []string{"token", "access_token", "refresh_token", "private_key"} {
		if query.Has(sensitiveKey) {
			return joinTarget{}, fault.New(fault.CodeInvalidInput, "parse invite URL", nil)
		}
	}
	if parsed.Scheme == "xconnect" {
		if parsed.Host != "join" {
			return joinTarget{}, fault.New(fault.CodeInvalidInput, "parse invite URL", nil)
		}
		controller := strings.TrimRight(strings.TrimSpace(query.Get("controller")), "/")
		if controller == "" {
			return joinTarget{}, fault.New(fault.CodeInvalidInput, "parse invite URL", nil)
		}
		return joinTarget{
			Controller: controller,
			NetworkID:  strings.TrimSpace(query.Get("network_id")),
			NodeID:     strings.TrimSpace(query.Get("node_id")),
		}, nil
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return joinTarget{}, fault.New(fault.CodeInvalidInput, "parse join target", nil)
	}
	if controller := strings.TrimSpace(query.Get("controller")); controller != "" {
		return joinTarget{
			Controller: strings.TrimRight(controller, "/"),
			NetworkID:  strings.TrimSpace(query.Get("network_id")),
			NodeID:     strings.TrimSpace(query.Get("node_id")),
		}, nil
	}
	if parsed.RawQuery != "" {
		return joinTarget{}, fault.New(fault.CodeInvalidInput, "parse join target", nil)
	}
	return joinTarget{Controller: strings.TrimRight(value, "/")}, nil
}

func defaultStateDirectory() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".xconnect-one"
	}
	return filepath.Join(home, ".xconnect-one")
}

func defaultDeviceID() string {
	hostname, _ := os.Hostname()
	raw := strings.ToLower("xconnect-" + runtime.GOOS + "-" + hostname)
	var normalized strings.Builder
	for _, character := range raw {
		if character >= 'a' && character <= 'z' || character >= '0' && character <= '9' || character == '-' || character == '_' || character == '.' {
			normalized.WriteRune(character)
		} else {
			normalized.WriteByte('-')
		}
	}
	return strings.Trim(normalized.String(), "-.")
}

func writeJSON(writer io.Writer, value any) error {
	encoder := json.NewEncoder(writer)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return fault.New(fault.CodeInvalidResponse, "write command output", err)
	}
	return nil
}
