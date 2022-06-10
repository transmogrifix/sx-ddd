unit Sx.DDD.Auth.Interfaces;

{$mode delphi}

interface

uses
  SysUtils,
  Classes,
  mormot.core.base,
  mormot.core.data,
  Sx.DDD.Core;

type
  /// the data type which will be returned during a password challenge
  // - in practice, will be e.g. Base-64 encoded SHA-256 binary hash
  TAuthQueryNonce = RawUTF8;

  TAuthInfoName = RawUTF8;

  /// DDD entity used to store authentication information
  TAuthInfo = class(TSynPersistent)
  protected
    fLogonName: TAuthInfoName;
  published
    /// the textual identifier by which the user would recognize himself
    property LogonName: TAuthInfoName read fLogonName write fLogonName;
  end;

  /// repository service to authenticate credentials via a dual pass challenge
  IDomAuthQuery = interface(ICQRSService)
    ['{5FB1E4A6-B432-413F-8958-1FA1857D1195}']
    /// initiate the first phase of a dual pass challenge authentication
    function ChallengeSelectFirst(const aLogonName: RawUTF8): TAuthQueryNonce;
    /// validate the first phase of a dual pass challenge authentication
    function ChallengeSelectFinal(const aChallengedPassword: TAuthQueryNonce): TCQRSResult;
    /// returns TRUE if the dual pass challenge did succeed
    function Logged: boolean;
    /// returns the logon name of the authenticated user
    function LogonName: RawUTF8;
    /// set the credential for Get() or further IAuthCommand.Update/Delete
    // - this method execution will be disabled for most clients
    function SelectByName(const aLogonName: RawUTF8): TCQRSResult;
    /// retrieve some information about the current selected credential
    function Get(out aAggregate: TAuthInfo): TCQRSResult;
  end;

  /// repository service to update or register new authentication credentials
  IDomAuthCommand = interface(IDomAuthQuery)
    ['{8252727B-336B-4105-80FD-C8DFDBD4801E}']
    /// register a new credential, from its LogonName/HashedPassword values
    // - aHashedPassword should match the algorithm expected by the actual
    // implementation class, over UTF-8 encoded LogonName+':'+Password
    // - on success, the newly created credential will be the currently selected
    function Add(const aLogonName: RawUTF8; aHashedPassword: TAuthQueryNonce): TCQRSResult;
    /// update the current selected credential password
    // - aHashedPassword should match the algorithm expected by the actual
    // implementation class, over UTF-8 encoded LogonName+':'+Password
    // - will be allowed only for the current challenged user
    function UpdatePassword(const aHashedPassword: TAuthQueryNonce): TCQRSResult;
    /// delete the current selected credential
    // - this method execution will be disabled for most clients
    function Delete: TCQRSResult;
    /// write all pending changes prepared by Add/UpdatePassword/Delete methods
    function Commit: TCQRSResult;
  end;


implementation

uses
  mormot.core.interfaces;

initialization

  TInterfaceFactory.RegisterInterfaces([TypeInfo(IDomAuthQuery),TypeInfo(IDomAuthCommand)]);

end.

