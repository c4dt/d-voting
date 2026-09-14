// Package types implements the packet and handshake messages for the tree
// routing algorithm.
//
// The messages have been implemented in this isolated package so that it does
// not create cycle imports when importing the serde formats.
//
// Documentation Last Review: 06.10.2020
package types

import "github.com/c4dt/d-voting/internal/serde"

// RegisterHandshakeFormat registers the engine for the provided format.
func RegisterHandshakeFormat(f serde.Format, e serde.FormatEngine) {
	hsFormats.Register(f, e)
}

// RegisterPacketFormat registers the engine for the provided format.
func RegisterPacketFormat(c serde.Format, f serde.FormatEngine) {
	packetFormat.Register(c, f)
}
