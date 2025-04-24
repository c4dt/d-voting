interface User {
  sciper: string;
  role: UserRole;
}

export const enum UserRole {
  // the strings for all the roles are compliant with the proxy api.
  // Check for any issue before updating any string value
  None = '',
  Admin = 'admin',
  Operator = 'operator',
  Voter = 'voter',
  Owner = 'owner',
}

export type { User };
