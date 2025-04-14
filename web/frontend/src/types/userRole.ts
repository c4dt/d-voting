interface User {
  sciper: string;
  role: UserRole;
}

export const enum UserRole {
  None = '',
  Admin = 'admin',
  Operator = 'operator',
  // the string for the 2 next role is compliant with the proxy api. Check for any issue before updating it
  Voter = 'voter',
  Owner = 'owner',
}

export type { User };
