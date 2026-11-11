package main

// Decoy secrets, made fresh for every run.
//
// They follow the shape of the real thing (OpenSSH keys, AWS key pairs, npm
// and GitHub tokens) so that code looking for credentials treats them as
// real. Nothing in them is fixed, so publishing this source does not let
// anyone recognise them by content. None of them is valid anywhere.
//
// Two of them name hosts. The npm token is tied to a registry under
// ".internal", a name reserved for private networks, so npm never sends it to
// the public registry (which would reject the install). The GitHub ones name
// github.com, where they are only sent if a server asks for a login.

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"strings"
)

const (
	alnum       = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	lowerAlnum  = "abcdefghijklmnopqrstuvwxyz0123456789"
	lowerLetter = "abcdefghijklmnopqrstuvwxyz"
	base32Upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
	digits      = "0123456789"
	urlSafe     = alnum + "-_"
)

func randomBytes(n int) []byte {
	b := make([]byte, n)
	_, _ = rand.Read(b) // never fails on Go 1.24+
	return b
}

// randomFrom picks n characters from set. The small bias from the modulo
// does not matter for decoys.
func randomFrom(set string, n int) string {
	out := make([]byte, n)
	for i, b := range randomBytes(n) {
		out[i] = set[int(b)%len(set)]
	}
	return string(out)
}

func pick(choices ...string) string {
	return choices[int(randomBytes(1)[0])%len(choices)]
}

// opensshKey looks like a real OpenSSH private key file: the right header,
// the "openssh-key-v1" magic, base64 in 70-character lines.
func opensshKey(size int) string {
	raw := append([]byte("openssh-key-v1\x00"), randomBytes(size)...)
	enc := base64.StdEncoding.EncodeToString(raw)
	var b strings.Builder
	b.WriteString("-----BEGIN OPENSSH PRIVATE KEY-----\n")
	for len(enc) > 70 {
		b.WriteString(enc[:70] + "\n")
		enc = enc[70:]
	}
	b.WriteString(enc + "\n-----END OPENSSH PRIVATE KEY-----\n")
	return b.String()
}

// makeDecoys returns home-relative path -> contents for one run.
func makeDecoys() map[string]string {
	user := pick("alex", "sam", "jordan", "taylor", "chris", "morgan", "jamie", "robin") + randomFrom(digits, 2)
	githubToken := func() string { return "ghp_" + randomFrom(alnum, 36) }
	dockerAuth := base64.StdEncoding.EncodeToString([]byte(user + ":dckr_pat_" + randomFrom(urlSafe, 27)))
	kubeToken := "eyJhbGciOiJSUzI1NiIsImtpZCI6" + randomFrom(urlSafe, 40) + "." + randomFrom(urlSafe, 120) + "." + randomFrom(urlSafe, 86)

	return map[string]string{
		".ssh/id_rsa":     opensshKey(1800),
		".ssh/id_ed25519": opensshKey(380),
		".aws/credentials": fmt.Sprintf("[default]\naws_access_key_id = AKIA%s\naws_secret_access_key = %s\nregion = %s\n",
			randomFrom(base32Upper, 16), randomFrom(alnum+"/+", 40), pick("us-east-1", "us-west-2", "eu-west-1", "eu-west-2")),
		".npmrc":              fmt.Sprintf("//npm.%s.internal/:_authToken=npm_%s\n", randomFrom(lowerLetter, 6), randomFrom(alnum, 36)),
		".netrc":              fmt.Sprintf("machine github.com\n  login %s\n  password %s\n", user, githubToken()),
		".git-credentials":    fmt.Sprintf("https://%s:%s@github.com\n", user, githubToken()),
		".docker/config.json": fmt.Sprintf(`{"auths":{"https://index.docker.io/v1/":{"auth":"%s"}}}`+"\n", dockerAuth),
		".kube/config": fmt.Sprintf("apiVersion: v1\nkind: Config\nclusters:\n- cluster:\n    server: https://k8s.%s.internal:6443\n  name: prod\n"+
			"contexts:\n- context:\n    cluster: prod\n    user: deploy\n  name: prod\ncurrent-context: prod\n"+
			"users:\n- name: deploy\n  user:\n    token: %s\n", randomFrom(lowerLetter, 6), kubeToken),
		".config/gcloud/application_default_credentials.json": fmt.Sprintf(
			`{"client_id":"%s-%s.apps.googleusercontent.com","client_secret":"GOCSPX-%s","refresh_token":"1//0%s","type":"authorized_user"}`+"\n",
			randomFrom(digits, 12), randomFrom(lowerAlnum, 32), randomFrom(urlSafe, 28), randomFrom(urlSafe, 100)),
	}
}

// randomHostname gives the VM an ordinary-looking name, e.g. "dev-3f9a".
func randomHostname() string {
	return pick("dev", "build", "workstation", "laptop", "ci") + "-" + randomFrom("0123456789abcdef", 4)
}
