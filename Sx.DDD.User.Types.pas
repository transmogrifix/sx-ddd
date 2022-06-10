unit Sx.DDD.User.Types;

{$mode delphi}

interface

uses
  mormot.core.base,
  mormot.core.data;

type
  /// how a confirmation email is to be rendered, for email address validation
  // - this information will be available as data context, e.g. to the Mustache
  // template used for rendering of the email body
  TDomUserEmailTemplate = class(TSynPersistent)
  private
    fFileName: RawUTF8;
    fSenderEmail: RawUTF8;
    fSubject: RawUTF8;
    fApplication: RawUTF8;
    fInfo: variant;
  published
    /// the local file name of the Mustache template
    property FileName: RawUTF8 read fFileName write fFileName;
    /// the "sender" field of the validation email
    property SenderEmail: RawUTF8 read fSenderEmail write fSenderEmail;
    /// the "subject" field of the validation email
    property Subject: RawUTF8 read fSubject write fSubject;
    /// the name of the application, currently sending the confirmation
    property Application: RawUTF8 read fApplication write fApplication;
    /// any unstructured additional information, also supplied as data context
    property Info: variant read fInfo write fInfo;
  end;

implementation

end.

