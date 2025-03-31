interface User {
  sciper: string;
  role: UserRole;
}

export const enum UserRole {
  Admin = 'admin',
  Operator = 'operator',
  Voter = 'voter',
  Owner = 'owner',
}

export type { User };
