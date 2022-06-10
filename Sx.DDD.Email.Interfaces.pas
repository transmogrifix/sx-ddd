unit Sx.DDD.Email.Interfaces;

{$mode delphi}

interface

uses
  mormot.core.base,
  Sx.DDD.Core,
  Sx.DDD.User.Types;

type
  /// defines a service able to check the correctness of email addresses
  // - will be implemented e.g. by TDDDEmailServiceAbstract and
  // TDDDEmailValidationService as defined in the dddInfraEmail unit
  IDomUserEmailCheck = interface(IInvokable)
    ['{2942BC2D-84F7-4A79-8657-07F0602C3505}']
    /// check if the supplied email address seems correct
    function CheckRecipient(const aEmail: RawUTF8): TCQRSResult;
    /// check if the supplied email addresses seem correct
    function CheckRecipients(const aEmails: TRawUTF8DynArray): TCQRSResult;
  end;

  /// defines a service sending a confirmation email to validate an email address
  // - will be implemented e.g. by TDDDEmailValidationService as defined in
  // the dddInfraEmail unit
  IDomUserEmailValidation = interface(IDomUserEmailCheck)
    ['{20129489-5054-4D4A-84B9-463DB98156B8}']
    /// internal method used to compute the validation URI
    // - will be included as data context to the email template, to create the
    // validation link
    function ComputeURIForReply(const aLogonName,aEmail: RawUTF8): RawUTF8;
    /// initiate an email validation process, using the given template
    function StartEmailValidation(const aTemplate: TDomUserEmailTemplate;
      const aLogonName,aEmail: RawUTF8): TCQRSResult;
    function IsEmailValidated(const aLogonName,aEmail: RawUTF8): boolean;
  end;

  /// defines a generic service able to send emails
  // - will be implemented e.g. by TDDDEmailerDaemon as defined in the
  // dddInfraEmailer unit
  IDomUserEmailer = interface(IInvokable)
    ['{20B88FCA-B345-4D5E-8E07-4581C814AFD9}']
    function SendEmail(const aRecipients: TRawUTF8DynArray;
      const aSender,aSubject,aHeaders,aBody: RawUTF8): TCQRSResult;
  end;

  /// defines a service for generic rendering of a template
  // - will be implemented e.g. via our SynMustache engine by TDDDTemplateAbstract
  // and TDDDTemplateFromFolder as defined in the dddInfraEmailer unit
  IDomUserTemplate = interface(IInvokable)
    ['{378ACC52-46BE-488D-B7ED-3F4E59316DFF}']
    function ComputeMessage(const aContext: variant;
      const aTemplateName: RawUTF8): RawUTF8;
  end;


implementation

uses
  mormot.core.interfaces;

initialization
  TInterfaceFactory.RegisterInterfaces(
    [TypeInfo(IDomUserEmailValidation),TypeInfo(IDomUserEmailer),
     TypeInfo(IDomUserTemplate)]);

end.

