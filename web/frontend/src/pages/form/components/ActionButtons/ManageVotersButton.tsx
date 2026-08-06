import { DocumentAddIcon } from '@heroicons/react/outline';
import { useTranslation } from 'react-i18next';
import { isManager } from './../../../../utils/auth';
import { AuthContext } from 'index';
import { useContext } from 'react';
import IndigoSpinnerIcon from '../IndigoSpinnerIcon';
import { OngoingAction } from 'types/form';

const ManageVotersButton = ({ handleManageVoters, formID, ongoingAction }) => {
  const { t } = useTranslation();
  const authCtx = useContext(AuthContext);

  return ongoingAction !== OngoingAction.ManageVoters ? (
    isManager(formID, authCtx) && (
      <button data-testid="manageVotersButton" onClick={handleManageVoters}>
        <div className="whitespace-nowrap inline-flex items-center justify-center px-4 py-1 mr-2 border border-gray-300 text-sm rounded-full font-medium text-gray-700 hover:text-red-500">
          <DocumentAddIcon className="-ml-1 mr-2 h-5 w-5" aria-hidden="true" />
          {t('manageVoters')}
        </div>
      </button>
    )
  ) : (
    <div className="whitespace-nowrap inline-flex items-center justify-center px-4 py-1 mr-2 border border-gray-300 text-sm rounded-full font-medium text-gray-700">
      <IndigoSpinnerIcon />
      {t('manageVotersLoading')}
    </div>
  );
};
export default ManageVotersButton;
