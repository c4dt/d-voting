import { User, UserRole } from 'types/userRole';

const mockUser1: User = {
  sciper: '123456',
  role: UserRole.Admin,
};

const mockUser2: User = {
  sciper: '234567',
  role: UserRole.Operator,
};

const mockUser3: User = {
  sciper: '345678',
  role: UserRole.Operator,
};

const user: User = {
  sciper: '561934',
  role: UserRole.Admin,
};

const setupMockUserDB = (): User[] => {
  const userDB: User[] = [];
  userDB.push(mockUser1);
  userDB.push(mockUser2);
  userDB.push(mockUser3);
  userDB.push(user);
  return userDB;
};

export default setupMockUserDB;
