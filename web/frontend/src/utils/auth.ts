import { ID } from '../types/configuration';
import { AuthState } from '../index';
import { UserRole } from '../types/userRole';

export function isManager(formID: ID, authState: AuthState) {
  return (
    authState.isLogged && // must be logged in and
    (authState.isAdmin || // must either be admin
      (authState.formsAuthorizations.has(formID) &&
        authState.formsAuthorizations.get(formID).includes(UserRole.Owner))) // or must own the election
  );
}

export function isVoter(formID: ID, authorization: Map<String, String[]>, isLogged: boolean) {
  return (
    isLogged && // must be logged in
    authorization.has(formID) &&
    authorization.get(formID).includes('vote') // must be able to vote in the election
  );
}
