package proxy

import (
	"bytes"
	"context"
	"crypto/sha256"
	b64 "encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/dedis/d-voting/contracts/evoting"
	ptypes "github.com/dedis/d-voting/proxy/types"
	"github.com/gorilla/mux"
	"go.dedis.ch/dela/core/execution/native"
	"go.dedis.ch/dela/core/txn"
	"go.dedis.ch/dela/crypto"
	"golang.org/x/xerrors"
)

// IsTxnIncluded
func (h *form) IsTxnIncluded(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)

	// check if the formID is valid
	if vars == nil || vars["token"] == "" {
		http.Error(w, fmt.Sprintf("token not found: %v", vars), http.StatusInternalServerError)
		return
	}

	token := vars["token"]

	marshall, err := b64.URLEncoding.DecodeString(token)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to decode token: %v", err), http.StatusInternalServerError)
		return
	}

	var content ptypes.TransactionInfo
	json.Unmarshal(marshall, &content)

	//h.logger.Info().Msg(fmt.Sprintf("Transaction infos: %+v", content))

	// get the status of the transaction as byte
	if content.Status != ptypes.UnknownTransactionStatus {
		http.Error(w, "the transaction status is known", http.StatusBadRequest)
		return
	}

	// get the signature as a crypto.Signature
	signature, err := h.signer.GetSignatureFactory().SignatureOf(h.context, content.Signature)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to get Signature: %v", err), http.StatusInternalServerError)
		return
	}

	// check if the hash is valid
	if !h.checkHash(content.Status, content.TransactionID, content.LastBlockIdx, content.Time, content.Hash) {
		http.Error(w, "invalid hash", http.StatusInternalServerError)
		return
	}

	// check if the signature is valid
	if !h.checkSignature(content.Hash, signature) {
		http.Error(w, "invalid signature", http.StatusInternalServerError)
		return
	}

	// check if if was submited not to long ago
	if time.Now().Unix()-content.Time > int64(maxTimeTransactionCheck) {
		http.Error(w, "the transaction is too old", http.StatusInternalServerError)
		return
	}

	if time.Now().Unix()-content.Time < 0 {
		http.Error(w, "the transaction is from the future", http.StatusInternalServerError)
		return
	}

	// check if the transaction is included in the blockchain
	newStatus, idx := h.checkTxnIncluded(content.TransactionID, content.LastBlockIdx)

	err = h.sendTransactionInfo(w, content.TransactionID, idx, newStatus)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to send transaction info: %v", err), http.StatusInternalServerError)
		return
	}

}

// checkHash checks if the hash is valid
func (h *form) checkHash(status ptypes.TransactionStatus, transactionID []byte, LastBlockIdx uint64, Time int64, Hash []byte) bool {
	// create the hash
	hash := sha256.New()
	hash.Write([]byte{byte(status)})
	hash.Write(transactionID)
	hash.Write([]byte(strconv.FormatUint(LastBlockIdx, 10)))
	hash.Write([]byte(strconv.FormatInt(Time, 10)))

	// check if the hash is valid
	return bytes.Equal(hash.Sum(nil), Hash)
}

// checkSignature checks if the signature is valid
func (h *form) checkSignature(Hash []byte, Signature crypto.Signature) bool {
	// check if the signature is valid

	return h.signer.GetPublicKey().Verify(Hash, Signature) == nil
}

// checkTxnIncluded checks if the transaction is included in the blockchain
func (h *form) checkTxnIncluded(transactionID []byte, lastBlockIdx uint64) (ptypes.TransactionStatus, uint64) {
	// first get the block
	idx := lastBlockIdx

	for {

		blockLink, err := h.blocks.GetByIndex(idx)
		// if we reached the end of the blockchain
		if err != nil {
			return ptypes.UnknownTransactionStatus, idx - 1
		}

		transactions := blockLink.GetBlock().GetTransactions()
		for _, txn := range transactions {
			if bytes.Equal(txn.GetID(), transactionID) {
				return ptypes.IncludedTransaction, blockLink.GetBlock().GetIndex()
			}

		}

		idx++
	}
}


// submitTxn submits a transaction
// Returns the transaction ID.
func (h *form) submitTxn(ctx context.Context, cmd evoting.Command,
	cmdArg string, payload []byte) ([]byte, uint64, error) {

	h.Lock()
	defer h.Unlock()

	err := h.mngr.Sync()
	if err != nil {
		return nil, 0, xerrors.Errorf("failed to sync manager: %v", err)
	}

	tx, err := createTransaction(h.mngr, cmd, cmdArg, payload)
	if err != nil {
		return nil, 0, xerrors.Errorf("failed to create transaction: %v", err)
	}

	// get the last block
	lastBlock, err := h.blocks.Last()
	if err != nil {
		return nil, 0, xerrors.Errorf("failed to get last block: %v", err)
	}
	lastBlockIdx := lastBlock.GetBlock().GetIndex()

	err = h.pool.Add(tx)
	if err != nil {
		return nil, 0, xerrors.Errorf("failed to add transaction to the pool: %v", err)
	}

	return tx.GetID(), lastBlockIdx, nil
}

func (h *form) sendTransactionInfo(w http.ResponseWriter, txnID []byte, lastBlockIdx uint64, status ptypes.TransactionStatus) error {

	response, err := h.CreateTransactionInfoToSend(txnID, lastBlockIdx, status)
	if err != nil {
		return xerrors.Errorf("failed to create transaction info: %v", err)
	}
	return sendResponse(w, response)

}

func (h *form) CreateTransactionInfoToSend(txnID []byte, lastBlockIdx uint64, status ptypes.TransactionStatus) (ptypes.TransactionInfoToSend, error) {

	time := time.Now().Unix()
	hash := sha256.New()

	// write status which is a byte to the hash as a []byte
	hash.Write([]byte{byte(status)})
	hash.Write(txnID)
	hash.Write([]byte(strconv.FormatUint(lastBlockIdx, 10)))
	hash.Write([]byte(strconv.FormatInt(time, 10)))

	finalHash := hash.Sum(nil)

	signature, err := h.signer.Sign(finalHash)

	if err != nil {
		return ptypes.TransactionInfoToSend{}, xerrors.Errorf("failed to sign transaction info: %v", err)
	}
	//convert signature to []byte
	signatureBin, err := signature.Serialize(h.context)
	if err != nil {
		return ptypes.TransactionInfoToSend{}, xerrors.Errorf("failed to marshal signature: %v", err)
	}

	infos := ptypes.TransactionInfo{
		Status:        status,
		TransactionID: txnID,
		LastBlockIdx:  lastBlockIdx,
		Time:          time,
		Hash:          finalHash,
		Signature:     signatureBin,
	}
	marshal, err := json.Marshal(infos)
	if err != nil {
		return ptypes.TransactionInfoToSend{}, xerrors.Errorf("failed to marshal transaction info: %v", err)
	}

	token := b64.URLEncoding.EncodeToString(marshal)

	response := ptypes.TransactionInfoToSend{
		Status: status,
		Token:  token,
	}
	h.logger.Info().Msg(fmt.Sprintf("Transaction info: %v", response))
	return response, nil
}

func sendResponse(w http.ResponseWriter, response any) error {

	w.Header().Set("Content-Type", "application/json")

	// Status et token

	err := json.NewEncoder(w).Encode(response)
	if err != nil {
		http.Error(w, "failed to write in ResponseWriter: "+err.Error(),
			http.StatusInternalServerError)
		return nil
	}

	return nil
}

// createTransaction creates a transaction with the given command and payload.
func createTransaction(manager txn.Manager, commandType evoting.Command,
	commandArg string, buf []byte) (txn.Transaction, error) {

	args := []txn.Arg{
		{
			Key:   native.ContractArg,
			Value: []byte(evoting.ContractName),
		},
		{
			Key:   evoting.CmdArg,
			Value: []byte(commandType),
		},
		{
			Key:   commandArg,
			Value: buf,
		},
	}

	tx, err := manager.Make(args...)
	if err != nil {
		return nil, xerrors.Errorf("failed to create transaction from manager: %v", err)
	}

	return tx, nil
}
