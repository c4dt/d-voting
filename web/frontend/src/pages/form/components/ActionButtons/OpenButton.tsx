import { LockOpenIcon } from '@heroicons/react/outline';
import { AuthContext } from 'index';
import { useContext } from 'react';
import { useTranslation } from 'react-i18next';
import { OngoingAction, Status } from 'types/form';
import ActionButton from './ActionButton';
import { isManager } from './../../../../utils/auth';

const OpenButton = ({ status, handleOpen, ongoingAction, formID }) => {
  const { t } = useTranslation();
  const authCtx = useContext(AuthContext);

  return (
    isManager(formID, authCtx) &&
    status === Status.Setup && (
      <ActionButton
        handleClick={handleOpen}
        ongoing={ongoingAction === OngoingAction.Opening}
        ongoingText={t('opening')}>
        <>
          <LockOpenIcon className="-ml-1 mr-2 h-5 w-5" aria-hidden="true" />
          {t('open')}
        </>
      </ActionButton>
    )
  );
};

export default OpenButton;
