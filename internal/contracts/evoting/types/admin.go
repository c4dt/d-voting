package types

import (
	"crypto/sha256"

	"github.com/c4dt/d-voting/internal/core/store"
	"github.com/c4dt/d-voting/internal/serde"
	"github.com/c4dt/d-voting/internal/serde/registry"
	"golang.org/x/xerrors"
)

var adminListFormat = registry.NewSimpleRegistry()

func RegisterAdminListFormat(format serde.Format, engine serde.FormatEngine) {
	adminListFormat.Register(format, engine)
}

// Used for both admins and operators rights management
type AdminList struct {
	// List of SCIPER with admin rights
	AdminList []int
}

func (adminList AdminList) Serialize(ctx serde.Context) ([]byte, error) {
	format := adminListFormat.Get(ctx.GetFormat())

	data, err := format.Encode(ctx, adminList)
	if err != nil {
		return nil, xerrors.Errorf("Failed to encode AdminList: %v", err)
	}

	return data, nil
}

func (adminList AdminList) Deserialize(ctx serde.Context, data []byte) (serde.Message, error) {
	format := adminListFormat.Get(ctx.GetFormat())

	message, err := format.Decode(ctx, data)
	if err != nil {
		return nil, xerrors.Errorf("Failed to decode: %v", err)
	}

	return message, nil
}

// AddAdmin add a new admin to the system.
func (adminList *AdminList) AddAdmin(userID string) error {
	sciperInt, err := SciperToInt(userID)
	if err != nil {
		return xerrors.Errorf("Failed to convert SCIPER to int: %v", err)
	}

	index, err := adminList.GetAdminIndex(userID)
	if err != nil {
		return err
	}

	if index > -1 {
		return xerrors.Errorf("The user %v is already an admin", userID)
	}

	adminList.AdminList = append(adminList.AdminList, sciperInt)

	return nil
}

// GetAdminIndex return the index of admin if userID is one, else return -1
func (adminList *AdminList) GetAdminIndex(userID string) (int, error) {
	sciperInt, err := SciperToInt(userID)
	if err != nil {
		return -1, xerrors.Errorf("Failed to convert SCIPER to int: %v", err)
	}

	for i := 0; i < len(adminList.AdminList); i++ {
		if adminList.AdminList[i] == sciperInt {
			return i, nil
		}
	}

	return -1, nil
}

// RemoveAdmin add a new admin to the admin list.
func (adminList *AdminList) RemoveAdmin(userID string) error {
	index, err := adminList.GetAdminIndex(userID)
	if err != nil {
		return xerrors.Errorf("Failed to retrieve the admin from the Admin List: %v", err)
	}

	if index < 0 {
		return xerrors.Errorf("Error while retrieving the index of the element.")
	}

	adminList.AdminList = append(adminList.AdminList[:index], adminList.AdminList[index+1:]...)
	return nil
}

func AdminListFromStore(ctx serde.Context, adminListFac serde.Factory, store store.Readable, adminListId string) (AdminList, error) {
	adminList := AdminList{}

	h := sha256.New()
	h.Write([]byte(adminListId))
	adminListIDBuf := h.Sum(nil)

	adminListBuf, err := store.Get(adminListIDBuf)
	if err != nil {
		return adminList, xerrors.Errorf("While getting data for list: %v", err)
	}
	if len(adminListBuf) == 0 {
		return adminList, xerrors.Errorf("No list found")
	}

	message, err := adminListFac.Deserialize(ctx, adminListBuf)
	if err != nil {
		return adminList, xerrors.Errorf("failed to deserialize AdminList: %v", err)
	}

	adminList, ok := message.(AdminList)
	if !ok {
		return adminList, xerrors.Errorf("Wrong message type: %T", message)
	}

	return adminList, nil
}

// AdminListFactory provides the mean to deserialize a AdminList. It naturally
// uses the formFormat.
//
// - implements serde.Factory
type AdminListFactory struct{}

// Deserialize implements serde.Factory
func (AdminListFactory) Deserialize(ctx serde.Context, data []byte) (serde.Message, error) {
	format := adminListFormat.Get(ctx.GetFormat())

	message, err := format.Decode(ctx, data)
	if err != nil {
		return nil, xerrors.Errorf("failed to decode: %v", err)
	}

	return message, nil
}
