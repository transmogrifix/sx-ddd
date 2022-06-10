unit Sx.DDD.Infra.Auth.Rest;

{$mode delphi}

interface

uses
  SysUtils,
  Classes,
  mormot.core.base,
  mormot.orm.base,
  mormot.orm.core,
  mormot.rest.core,
  Sx.DDD.Core,
  Sx.DDD.Auth.Interfaces;


{ ----- Authentication Implementation using SHA-256 dual step challenge }

type
  /// ORM object to persist authentication information, i.e. TAuthInfo
  TOrmUserAuth = class(TOrm)
  protected
    fLogon: RawUTF8;
    fHashedPassword: RawUTF8;
    class procedure InternalDefineModel(Props: TOrmProperties); override;
  published
    /// will map TAuthInfo.LogonName
    // - is defined as "stored AS_UNIQUE" so that it may be used as primary key
    property Logon: RawUTF8 read fLogon write fLogon stored AS_UNIQUE;
    /// the password, stored in a hashed form
    // - this property does not exist at TAuthInfo level, so will be private
    // to the storage layer - which is the safest option possible
    property HashedPassword: RawUTF8 read fHashedPassword write fHashedPassword;
  end;

  /// generic class for implementing authentication
  // - do not instantiate this abstract class, but e.g. TDDDAuthenticationSHA256
  // or TDDDAuthenticationMD5
  TDDDAuthenticationAbstract = class(TDDDRepositoryRestCommand,IDomAuthCommand)
  protected
    fChallengeLogonName: RawUTF8;
    fChallengeNonce: TAuthQueryNonce;
    fLogged: boolean;
    // inherited classes should override this method with the proper algorithm
    class function DoHash(const aValue: TAuthQueryNonce): TAuthQueryNonce; virtual; abstract;
  public
    /// initiate the first phase of a dual pass challenge authentication
    function ChallengeSelectFirst(const aLogonName: RawUTF8): TAuthQueryNonce;
    /// validate the first phase of a dual pass challenge authentication
    function ChallengeSelectFinal(const aChallengedPassword: TAuthQueryNonce): TCQRSResult;
    /// set the credential for Get() or further IDomAuthCommand.Update/Delete
    // - this method execution will be disabled for most clients
    function SelectByName(const aLogonName: RawUTF8): TCQRSResult;
    /// returns TRUE if the dual pass challenge did succeed
    function Logged: boolean;
    /// returns the logon name of the authenticated user
    function LogonName: RawUTF8;
    /// retrieve some information about the current selected credential
    function Get(out aAggregate: TAuthInfo): TCQRSResult;
    /// register a new credential, from its LogonName/HashedPassword values
    // - on success, the newly created credential will be the currently selected
    function Add(const aLogonName: RawUTF8; aHashedPassword: TAuthQueryNonce): TCQRSResult;
    /// update the current selected credential password
    function UpdatePassword(const aHashedPassword: TAuthQueryNonce): TCQRSResult;
    /// class method to be used to compute a password hash from its plain value
    class function ComputeHashPassword(const aLogonName,aPassword: RawUTF8): TAuthQueryNonce;
    /// class method to be used on the client side to resolve the challenge
    // - is basically
    // !   result := DoHash(aLogonName+':'+aChallengeFromServer+':'+
    // !     ComputeHashPassword(aLogonName,aPlainPassword));
    class function ClientComputeChallengedPassword(
      const aLogonName,aPlainPassword: RawUTF8;
      const aChallengeFromServer: TAuthQueryNonce): TAuthQueryNonce; virtual;
  end;

  /// allows to specify which actual hashing algorithm would be used
  // - i.e. either TDDDAuthenticationSHA256 or TDDDAuthenticationMD5
  TDDDAuthenticationClass = class of TDDDAuthenticationAbstract;

  /// implements authentication using SHA-256 hashing
  // - more secure than TDDDAuthenticationMD5
  TDDDAuthenticationSHA256 = class(TDDDAuthenticationAbstract)
  protected
    /// will use SHA-256 algorithm for hashing, and the class name as salt
    class function DoHash(const aValue: TAuthQueryNonce): TAuthQueryNonce; override;
  end;

  /// implements authentication using MD5 hashing
  // - less secure than TDDDAuthenticationSHA256
  TDDDAuthenticationMD5 = class(TDDDAuthenticationAbstract)
  protected
    /// will use MD5 algorithm for hashing, and the class name as salt
    class function DoHash(const aValue: TAuthQueryNonce): TAuthQueryNonce; override;
  end;

  /// abstract factory of IDomAuthCommand repository instances using REST
  TDDDAuthenticationRestFactoryAbstract = class(TDDDRepositoryRestFactory)
  protected
  public
    /// initialize a factory with the supplied implementation algorithm
    constructor Create(aRest: TRest; aImplementationClass: TDDDAuthenticationClass;
      aOwner: TDDDRepositoryRestManager); reintroduce;
  end;

  /// factory of IDomAuthCommand repository instances using a RESTful ORM access
  // and SHA-256 hashing algorithm
  TDDDAuthenticationRestFactorySHA256 = class(TDDDAuthenticationRestFactoryAbstract)
  protected
  public
    /// initialize a factory with the SHA-256 implementation algorithm
    constructor Create(aRest: TRest; aOwner: TDDDRepositoryRestManager=nil); reintroduce;
  end;

  /// factory of IDomAuthCommand repository instances using a RESTful ORM access
  // and SHA-256 hashing algorithm
  TDDDAuthenticationRestFactoryMD5 = class(TDDDAuthenticationRestFactoryAbstract)
  protected
  public
    /// initialize a factory with the SHA-256 implementation algorithm
    constructor Create(aRest: TRest; aOwner: TDDDRepositoryRestManager=nil); reintroduce;
  end;



implementation

uses
  mormot.core.datetime,
  mormot.crypt.core;


{ TDDDAuthenticationAbstract }

function TDDDAuthenticationAbstract.ChallengeSelectFirst(
  const aLogonName: RawUTF8): TAuthQueryNonce;
begin
  fLogged := false;
  fChallengeLogonName := Trim(aLogonName);
  fChallengeNonce := DoHash(aLogonName+NowToString);
  result := fChallengeNonce;
end;

function TDDDAuthenticationAbstract.ChallengeSelectFinal(
  const aChallengedPassword: TAuthQueryNonce): TCQRSResult;
begin
  if (fChallengeLogonName='') or (fChallengeNonce='') then
    result := CqrsSetResultError(cqrsBadRequest) else
    result := SelectByName(fChallengeLogonName);
  if result<>cqrsSuccess then
    exit;
  CqrsBeginMethod(qaNone, result);
  if DoHash(fChallengeLogonName+':'+fChallengeNonce+':'+
     (fCurrentORMInstance as TOrmUserAuth).HashedPassword)=aChallengedPassword then begin
    fLogged := true;
    CqrsSetResult(cqrsSuccess,result);
  end else
    CqrsSetResultMsg(cqrsBadRequest,'Wrong Password for [%]',[fChallengeLogonName],result);
  fChallengeNonce := '';
  fChallengeLogonName := '';
end;

function TDDDAuthenticationAbstract.LogonName: RawUTF8;
begin
  if (fCurrentORMInstance=nil) or not Logged then
    result := '' else
    result := TOrmUserAuth(fCurrentORMInstance).Logon;
end;

function TDDDAuthenticationAbstract.Logged: boolean;
begin
  result := fLogged;
end;

class function TDDDAuthenticationAbstract.ComputeHashPassword(
  const aLogonName, aPassword: RawUTF8): TAuthQueryNonce;
begin
  result := DoHash(aLogonName+':'+aPassword);
end;

class function TDDDAuthenticationAbstract.ClientComputeChallengedPassword(
  const aLogonName,aPlainPassword: RawUTF8; const aChallengeFromServer: TAuthQueryNonce): TAuthQueryNonce;
begin // see TDDDAuthenticationAbstract.ChallengeSelectFinal
  result := DoHash(aLogonName+':'+aChallengeFromServer+':'+
    ComputeHashPassword(aLogonName,aPlainPassword));
end;

function TDDDAuthenticationAbstract.SelectByName(
  const aLogonName: RawUTF8): TCQRSResult;
begin
  result := ORMSelectOne('Logon=?',[aLogonName],(aLogonName=''));
end;

function TDDDAuthenticationAbstract.Get(
  out aAggregate: TAuthInfo): TCQRSResult;
begin
  result := ORMGetAggregate(aAggregate);
end;

function TDDDAuthenticationAbstract.Add(const aLogonName: RawUTF8;
  aHashedPassword: TAuthQueryNonce): TCQRSResult;
begin
  if not CqrsBeginMethod(qaCommandDirect,result) then
    exit;
  with fCurrentORMInstance as TOrmUserAuth do begin
    Logon := aLogonName;
    HashedPassword := aHashedPassword;
  end;
  ORMPrepareForCommit(ooInsert,nil,result);
end;

function TDDDAuthenticationAbstract.UpdatePassword(
  const aHashedPassword: TAuthQueryNonce): TCQRSResult;
begin
  if not CqrsBeginMethod(qaCommandOnSelect,result) then
    exit;
  (fCurrentORMInstance as TOrmUserAuth).HashedPassword := aHashedPassword;
  ORMPrepareForCommit(ooUpdate,nil,result);
end;

{ TDDDAuthenticationSHA256 }

class function TDDDAuthenticationSHA256.DoHash(
  const aValue: TAuthQueryNonce): TAuthQueryNonce;
begin
  result := SHA256(RawUTF8(ClassName)+aValue);
end;

{ TDDDAuthenticationMD5 }

class function TDDDAuthenticationMD5.DoHash(
  const aValue: TAuthQueryNonce): TAuthQueryNonce;
begin
  result := MD5(RawUTF8(ClassName)+aValue);
end;


{ TDDDAuthenticationRestFactoryAbstract }

constructor TDDDAuthenticationRestFactoryAbstract.Create(aRest: TRest;
  aImplementationClass: TDDDAuthenticationClass;
  aOwner: TDDDRepositoryRestManager);
begin
  inherited Create(
    IDomAuthCommand,aImplementationClass,TAuthInfo,aRest,TOrmUserAuth,
    ['Logon','LogonName'],aOwner);
end;


{ TDDDAuthenticationRestFactorySHA256 }

constructor TDDDAuthenticationRestFactorySHA256.Create(aRest: TRest;
  aOwner: TDDDRepositoryRestManager);
begin
  inherited Create(aRest,TDDDAuthenticationSHA256,aOwner);
end;

{ TDDDAuthenticationRestFactoryMD5 }

constructor TDDDAuthenticationRestFactoryMD5.Create(aRest: TRest;
  aOwner: TDDDRepositoryRestManager);
begin
  inherited Create(aRest,TDDDAuthenticationMD5,aOwner);
end;



{ TOrmUserAuth }

class procedure TOrmUserAuth.InternalDefineModel(
  Props: TOrmProperties);
begin
  AddFilterNotVoidText(['Logon','HashedPassword']);
end;

end.
