package json

import (
	"github.com/c4dt/d-voting/internal/contracts/evoting/types"
	"github.com/c4dt/d-voting/internal/serde"
)

// Register the JSON formats for the form, ciphervote, and transaction

func init() {
	types.RegisterFormFormat(serde.FormatJSON, formFormat{})
	types.RegisterSuffragiaFormat(serde.FormatJSON, suffragiaFormat{})
	types.RegisterCiphervoteFormat(serde.FormatJSON, ciphervoteFormat{})
	types.RegisterTransactionFormat(serde.FormatJSON, transactionFormat{})
	types.RegisterAdminListFormat(serde.FormatJSON, adminListFormat{})
}
