import { ID } from '../types/configuration';
import { AuthState } from '../index';
import { UserRole } from '../types/userRole';
import { FormInfo, LightFormInfo } from '../types/form';

export function isManager(formID: ID, authState: AuthState) {
  return (
    authState.isLogged && // must be logged in and
    (authState.isAdmin || // must either be admin
      (authState.formsAuthorizations.has(formID) &&
        authState.formsAuthorizations.get(formID).includes(UserRole.Owner))) // or must own the election
  );
}

export function isVoter(formID: ID, authState: AuthState) {
  return (
    authState.isLogged && // must be logged in
    authState.formsAuthorizations.has(formID) &&
    authState.formsAuthorizations.get(formID).includes(UserRole.Voter) // must be able to vote in the election
  );
}

export function setFormAuth(form: LightFormInfo | FormInfo, authCtx: AuthState) {
  if (!form.Owners || !form.Voters) return;

  const roles = [];
  if (form.Voters.includes(authCtx.sciper.toString())) {
    roles.push(UserRole.Voter);
  }
  if (form.Owners.includes(authCtx.sciper.toString())) {
    roles.push(UserRole.Owner);
  }
  authCtx.formsAuthorizations.set(form.FormID, roles);
}
