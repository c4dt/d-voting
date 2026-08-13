package integration

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"

	"github.com/c4dt/d-voting/contracts/evoting"
	"github.com/c4dt/d-voting/contracts/evoting/types"
	"github.com/c4dt/d-voting/internal/testing/fake"
	"github.com/c4dt/d-voting/dela/core/execution/native"
	"github.com/c4dt/d-voting/dela/core/ordering"
	"github.com/c4dt/d-voting/dela/core/txn"
	"github.com/c4dt/d-voting/dela/serde"
	jsonDela "github.com/c4dt/d-voting/dela/serde/json"
	"golang.org/x/xerrors"
)

var serdecontext = jsonDela.NewContext()

func encodeID(ID string) types.ID {
	return types.ID(base64.StdEncoding.EncodeToString([]byte(ID)))
}

// for integration tests
func addAdmin(m txManager, admin string) error {
	addAdmin := types.AddAdmin{admin, admin}

	data, err := addAdmin.Serialize(serdecontext)
	if err != nil {
		return xerrors.Errorf("failed to serialize: %v", err)
	}

	args := []txn.Arg{
		{Key: native.ContractArg, Value: []byte(evoting.ContractName)},
		{Key: evoting.FormArg, Value: data},
		{Key: evoting.CmdArg, Value: []byte(evoting.CmdAddAdmin)},
	}

	_, err = m.addAndWait(args...)
	if err != nil {
		return xerrors.Errorf(addAndWaitErr, err)
	}

	return nil
}

// for integration tests
func createForm(m txManager, title string, admin string) ([]byte, error) {
	// Define the configuration :
	configuration := fake.BasicConfiguration

	createForm := types.CreateForm{
		Configuration: configuration,
		UserID:        admin,
	}

	data, err := createForm.Serialize(serdecontext)
	if err != nil {
		return nil, xerrors.Errorf("failed to serialize: %v", err)
	}

	args := []txn.Arg{
		{Key: native.ContractArg, Value: []byte(evoting.ContractName)},
		{Key: evoting.FormArg, Value: data},
		{Key: evoting.CmdArg, Value: []byte(evoting.CmdCreateForm)},
	}

	txID, err := m.addAndWait(args...)
	if err != nil {
		return nil, xerrors.Errorf(addAndWaitErr, err)
	}

	// Calculate formID from
	hash := sha256.New()
	hash.Write(txID)
	formID := hash.Sum(nil)

	return formID, nil
}

// for integration tests
func openForm(m txManager, formID []byte, userID string) error {
	openForm := &types.OpenForm{
		FormID: hex.EncodeToString(formID),
		UserID: userID,
	}

	data, err := openForm.Serialize(serdecontext)
	if err != nil {
		return xerrors.Errorf("failed to serialize open form: %v", err)
	}

	args := []txn.Arg{
		{Key: native.ContractArg, Value: []byte(evoting.ContractName)},
		{Key: evoting.FormArg, Value: data},
		{Key: evoting.CmdArg, Value: []byte(evoting.CmdOpenForm)},
	}

	_, err = m.addAndWait(args...)
	if err != nil {
		return xerrors.Errorf(addAndWaitErr, err)
	}

	return nil
}

func getForm(formFac serde.Factory, formID []byte,
	service ordering.Service) (types.Form, error) {

	return types.FormFromStore(serdecontext, formFac, hex.EncodeToString(formID), service.GetStore())
}

// for integration tests
func closeForm(m txManager, formID []byte, admin string) error {
	closeForm := &types.CloseForm{
		FormID: hex.EncodeToString(formID),
		UserID: admin,
	}

	data, err := closeForm.Serialize(serdecontext)
	if err != nil {
		return xerrors.Errorf("failed to serialize open form: %v", err)
	}

	args := []txn.Arg{
		{Key: native.ContractArg, Value: []byte(evoting.ContractName)},
		{Key: evoting.FormArg, Value: data},
		{Key: evoting.CmdArg, Value: []byte(evoting.CmdCloseForm)},
	}

	_, err = m.addAndWait(args...)
	if err != nil {
		return xerrors.Errorf("failed to Marshall closeForm: %v", err)
	}

	return nil
}
