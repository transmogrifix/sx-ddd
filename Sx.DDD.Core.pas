unit Sx.DDD.Core;

{$mode delphi}

interface

uses
  Classes,
  SysUtils,
  mormot.core.base,
  mormot.core.data,
  mormot.core.os,
  mormot.core.log,
  mormot.core.rtti,
  mormot.core.perf,
  mormot.core.search,
  mormot.core.text,
  mormot.core.threads,
  mormot.core.interfaces,
  mormot.rest.core,
  mormot.orm.base,
  mormot.orm.core,
  mormot.soa.core,
  mormot.soa.server;

type
  /// abstract ancestor for all Domain-Driven Design related Exceptions
  EDDDException = class(ESynException);

  /// Exception type linked to CQRS repository service methods
  ECQRSException = class(EDDDException);

  /// abstract ancestor for any Domain-Driven Design infrastructure Exceptions
  EDDDInfraException = class(EDDDException);


type
  /// result enumerate for I*Query/I*Command CQRS repository service methods
  // - cqrsSuccess will map the default TInterfaceStub returned value
  // - cqrsSuccessWithMoreData would be used e.g. for versioned publish/
  // subscribe to notify the caller that there are still data available, and
  // the call should be reiterated until cqrsSuccess is returned
  // - cqrsBadRequest would indicate that the method was not called in the
  // expected workflow sequence
  // - cqrsNotFound appear after a I*Query SelectBy*() method with no match
  // - cqrsNoMoreData indicates a GetNext*() method has no more matching data
  // - cqrsDataLayerError indicates a low-level error at database level
  // - cqrsInvalidCallback is returned if a callback is required for this method
  // - cqrsInternalError for an unexpected issue, like an Exception raised
  // - cqrsDDDValidationFailed will be trigerred when
  // - cqrsInvalidContent for any I*Command method with invalid aggregate input
  // value (e.g. a missing field)
  // - cqrsAlreadyExists for a I*Command.Add method with a primay key conflict
  // - cqrsNoPriorQuery for a I*Command.Update/Delete method with no prior
  // call to SelectBy*()
  // - cqrsNoPriorCommand for a I*Command.Commit with no prior Add/Update/Delete
  // - cqrsNoMatch will notify that a command did not have any match
  // - cqrsNotImplemented may be returned when there is no code yet for a method
  // - cqrsBusy is returned if the command could not be executed, since it is
  // currently processing a request
  // - cqrsTimeout indicates that the method didn't succeed in the expected time
  // - otherwise, cqrsUnspecifiedError will be used for any other kind of error
  TCQRSResult =
    (cqrsSuccess, cqrsSuccessWithMoreData,
     cqrsUnspecifiedError, cqrsBadRequest, cqrsNotFound,
     cqrsNoMoreData, cqrsDataLayerError, cqrsInvalidCallback,
     cqrsInternalError, cqrsDDDValidationFailed,
     cqrsInvalidContent, cqrsAlreadyExists,
     cqrsNoPriorQuery, cqrsNoPriorCommand,
     cqrsNoMatch, cqrsNotImplemented,
     cqrsBusy, cqrsTimeout);

  /// generic interface, to be used for CQRS I*Query and I*Command types definition
  // - TCQRSService class will allow to easily implement LastError* members
  // - all CQRS services, which may be executed remotely, would favor a function
  // result as TCQRSResult enumeration for error handling, rather than a local
  // Exception, which is not likely to be transferred easily on consummer side
  ICQRSService = interface(IInvokable)
    /// should return the last error as an enumerate
    // - when stubed or mocked via TInterfaceStub, any method interface would
    // return 0, i.e. cqrsSuccess by default, to let the test pass
    function GetLastError: TCQRSResult;
    /// should return addition information for the last error
    // - may be a plain string, or a JSON document stored as TDocVariant
    function GetLastErrorInfo: variant;
  end;

/// returns the text equivalency of a CQRS result enumeration
function ToText(res: TCQRSResult): PShortString; overload;

const
  /// successfull result enumerates for I*Query/I*Command CQRS
  // - those items would generate no log entry
  // - i.e. any command not included in CQRSRESULT_SUCCESS nor CQRSRESULT_WARNING
  // would trigger a sllDDDError log entry
  CQRSRESULT_SUCCESS = [
    cqrsSuccess, cqrsSuccessWithMoreData, cqrsNoMoreData, cqrsNotFound];

  /// dubious result enumerates for I*Query/I*Command CQRS
  // - those items would generate a sllDDDInfo log entry
  // - i.e. any command not included in CQRSRESULT_SUCCESS nor CQRSRESULT_WARNING
  // would trigger a sllDDDError log entry
  CQRSRESULT_WARNING = [
    cqrsNotFound, cqrsNoMatch];


{ ----- Services / Daemon Interfaces }

type
  /// generic interface, to be used so that you may retrieve a running state
  IMonitored = interface(IInvokable)
    ['{7F5E1569-E06B-48A0-954C-95784EC23363}']
    /// retrieve the current status of the instance
    // - the status is returned as a schema-less value (typically a TDocVariant
    // document), which may contain statistics about the current processing
    // numbers, timing and throughput
    function RetrieveState(out Status: variant): TCQRSResult;
  end;

  /// generic interface, to be used so that you may manage a service/daemon instance
  IMonitoredDaemon = interface(IMonitored)
    ['{F5717AFC-5D0E-4E13-BD5B-25C08CB177A7}']
    /// launch the service/daemon
    // - should first stop any previous running instance (so may be used to
    // restart a service on demand)
    function Start: TCQRSResult;
    /// abort the service/daemon, returning statistics about the whole execution
    function Stop(out Information: variant): TCQRSResult;
  end;

{ *********** Cross-Cutting Layer Implementation}

{ ----- Persistence / Repository CQRS Implementation }

type
  /// which kind of process is about to take place after an CqrsBeginMethod()
  TCQRSQueryAction = (
    qaNone,
    qaSelect, qaGet,
    qaCommandDirect, qaCommandOnSelect,
    qaCommit);

  /// define one or several process to take place after an CqrsBeginMethod()
  TCQRSQueryActions = set of TCQRSQueryAction;

  /// the current step of a TCQRSQuery state machine
  // - basic state diagram is defined by the methods execution:
  // - qsNone refers to the default state, with no currently selected values,
  // nor any pending write request
  // - qsQuery corresponds to a successful I*Query.Select*(), expecting
  // either a I*Query.Get*(), or a I*Command.Add/Update/Delete
  // - qsCommand corresponds to a successful I*Command.Add/Update/Delete,
  // expected a I*Command.Commit
  TCQRSQueryState = (qsNone, qsQuery, qsCommand);

  /// to be inherited to implement CQRS I*Query or I*Command services extended
  // error process
  // - you should never assign directly a cqrs* value to a method result, but
  // rather use the CqrsBeginMethod/CqrsSetResult/CqrsSetResultMsg methods provided by this class:
  // ! function TMyService.MyMethod: TCQRSResult;
  // ! begin
  // !   CqrsBeginMethod(qsNone,result); // reset the error information to cqrsUnspecifiedError
  // !   ... // do some work
  // !   if error then
  // !     CqrsSetResultMsg(cqrsUnspecifiedError,'Oups! For "%"',[name],result) else
  // !     CqrsSetResult(cqrsSuccess,result); // instead of result := cqrsSuccess
  // !   end;
  // - the methods are implemented as a simple state machine, following
  // the TCQRSQueryAction and TCQRSQueryState definitions
  // - warning: by definition, fLastError* access is NOT thread-safe so the
  // CqrsBeginMethod/CqrsSetResult feature should be used in a single context
  TCQRSService = class(TInjectableObject, ICQRSService)
  protected
    fLastError: TCQRSResult;
    fLastErrorContext: variant;
    fAction: TCQRSQueryAction;
    fState: TCQRSQueryState;
    {$ifdef WITHLOG}
    fLog: TSynLogFamily;
    {$endif}
    fSafe: TSynLocker;
    // method to be called at first for LastError process
    function CqrsBeginMethod(aAction: TCQRSQueryAction; var aResult: TCQRSResult;
      aError: TCQRSResult=cqrsUnspecifiedError): boolean; virtual;
    function CqrsSetResultError(aError: TCQRSResult): TCQRSResult; virtual;
    // methods to be used to set the process end status
    procedure CqrsSetResult(Error: TCQRSResult; var Result: TCQRSResult); overload;
    procedure CqrsSetResult(E: Exception; var Result: TCQRSResult); overload;
    procedure CqrsSetResultSuccessIf(SuccessCondition: boolean; var Result: TCQRSResult;
      ErrorIfFalse: TCQRSResult=cqrsDataLayerError);
    procedure CqrsSetResultMsg(Error: TCQRSResult; const ErrorMessage: RawUTF8;
        var Result: TCQRSResult); overload;
    procedure CqrsSetResultMsg(Error: TCQRSResult; const ErrorMsgFmt: RawUTF8;
      const ErrorMsgArgs: array of const; var Result: TCQRSResult); overload;
    procedure CqrsSetResultString(Error: TCQRSResult; const ErrorMessage: string;
      var Result: TCQRSResult);
    procedure CqrsSetResultDoc(Error: TCQRSResult; const ErrorInfo: variant;
      var Result: TCQRSResult);
    procedure CqrsSetResultJSON(Error: TCQRSResult; const JSONFmt: RawUTF8;
      const Args,Params: array of const; var Result: TCQRSResult);
    function GetLastError: TCQRSResult;
    function GetLastErrorInfo: variant; virtual;
    procedure InternalCqrsSetResult(Error: TCQRSResult; var Result: TCQRSResult); virtual;
    procedure AfterInternalCqrsSetResult; virtual;
  public
    /// initialize the instance
    constructor Create; override;
    /// finalize the instance
    destructor Destroy; override;
    {$ifdef WITHLOG}
    /// where logging should take place
    property Log: TSynLogFamily read fLog write fLog;
    {$endif}
  published
    /// the last error, as an enumerate
    property LastError: TCQRSResult read GetLastError;
    /// the last error extended information, as a string or TDocVariant
    property LastErrorInfo: variant read GetLastErrorInfo;
    /// the action currently processing
    property Action: TCQRSQueryAction read fAction;
    /// current step of the TCQRSService state machine
    property State: TCQRSQueryState read fState;
  end;

  /// a CQRS Service, which maintains an internal list of "Subscribers"
  // - allow to notify in cascade when a callback is released
  TCQRSServiceSubscribe = class(TCQRSService)
  protected
    fSubscriber: array of IServiceWithCallbackReleased;
    // will call all fSubscriber[].CallbackReleased() methods
    procedure CallbackReleased(const callback: IInvokable; const interfaceName: RawUTF8);
  end;

  /// a CQRS Service, ready to implement a set of synchronous (blocking) commands
  // over an asynchronous (non-blocking) service
  // - you may use this class e.g. at API level, over a blocking REST server,
  // and communicate with the Domain event-driven services via asynchronous calls
  // - this class won't inherit from TCQRSService, since it would be called
  // from multiple threads at once, so all CQRSSetResult() methods would fail
  TCQRSServiceSynch = class(TInterfacedObject)
  protected
    fSharedCallbackRef: IUnknown;
  public
    constructor Create(const sharedcallback: IUnknown); reintroduce;
  end;

  /// used to acknowledge asynchronous CQRS Service calls
  // - e.g. to implement TCQRSServiceSynch
  TCQRSServiceAsynchAck = class(TInterfacedObject)
  protected
    fLog: TSynLogClass;
    fCalls: TBlockingProcessPool;
  public
    destructor Destroy; override;
  end;

  /// class-reference type (metaclass) of TCQRSService
  TCQRSServiceClass = class of TCQRSService;

/// returns the text equivalency of a CQRS state enumeration
function ToText(res: TCQRSQueryState): PShortString; overload;


{ ----- Persistence / Repository Implementation using mORMot's ORM }

type
  TDDDRepositoryRestFactory = class;
  TDDDRepositoryRestQuery = class;

  /// class-reference type (metaclass) to implement I*Query or I*Command
  // interface definitions using our RESTful ORM
  TDDDRepositoryRestClass = class of TDDDRepositoryRestQuery;

  /// abstract ancestor for all persistence/repository related Exceptions
  EDDDRepository = class(ESynException)
  public
    /// constructor like FormatUTF8() which will also serialize the caller info
    constructor CreateUTF8(Caller: TDDDRepositoryRestFactory;
      const Format: RawUTF8; const Args: array of const);
  end;

  /// store reference of several factories, each with one mapping definition
  TDDDRepositoryRestFactoryObjArray = array of TDDDRepositoryRestFactory;

  /// home repository of several DDD Entity factories using REST storage
  // - this shared class will be can to manage a service-wide repositories,
  // e.g. manage actual I*Query/I*Command implementation classes accross a
  // set of TSQLRest instances
  // - is designed to optimize BATCH or transactional process
  TDDDRepositoryRestManager = class
  protected
    fFactory: TDDDRepositoryRestFactoryObjArray;
  public
    /// finalize all factories
    destructor Destroy; override;
    /// register one DDD Entity repository over an ORM's TSQLRecord
    // - will raise an exception if the aggregate has already been defined
    function AddFactory(
      const aInterface: TGUID; aImplementation: TDDDRepositoryRestClass;
      aAggregate: TClass; aRest: TRest; aTable: TOrmClass;
      const TableAggregatePairs: array of RawUTF8): TDDDRepositoryRestFactory;
    /// retrieve the registered definition of a given DDD Entity in Factory[]
    // - returns -1 if the TPersistence class is unknown
    function GetFactoryIndex(const aInterface: TGUID): integer;
    /// retrieve the registered Factory definition of a given DDD Entity
    // - raise an EDDDRepository exception if the TPersistence class is unknown
    function GetFactory(const aInterface: TGUID): TDDDRepositoryRestFactory;
    /// read-only access to all defined DDD Entity factories
    property Factory: TDDDRepositoryRestFactoryObjArray read fFactory;
  end;

  /// implement a DDD Entity factory over one ORM's TSQLRecord
  // - it will centralize some helper classes and optimized class mapping
  // - the Entity class may be defined as any TPersistent or TSynPersistent, with
  // an obvious preference for TSynPersistent and TSynAutoCreateFields classes
  TDDDRepositoryRestFactory = class(TInterfaceResolverForSingleInterface)
  private
    function GetAggregateClass: TClass;
  protected
    fOwner: TDDDRepositoryRestManager;
    fInterface: TInterfaceFactory;
    fRest: TRest;
    fTable: TOrmClass;
    fAggregate: TRttiCustom;// TClassInstance;
    fAggregateRTTI: TOrmPropInfoList;
    // stored in fGarbageCollector, following fAggregateProp[]
    fGarbageCollector: TObjectDynArray;
    fFilter: array of array of TSynFilter;
    fValidate: array of array of TSynValidate;
    // TSQLPropInfoList correspondance, as filled by ComputeMapping:
    fAggregateToTable: TOrmPropInfoObjArray;
    fAggregateProp: TOrmPropInfoRttiObjArray;
    fAggregateID: TOrmPropInfoRtti;
    // store custom field mapping between TSQLRecord and Aggregate
    fPropsMapping: TOrmPropertiesMapping;
    fPropsMappingVersion: cardinal;
    procedure ComputeMapping;
    function GetAggregateName: string;
    function GetTableName: string;
    // override those methods to customize the data marshalling
    procedure AggregatePropToTable(
      aAggregate: TObject; aAggregateProp: TOrmPropInfo;
      aRecord: TOrm; aRecordProp: TOrmPropInfo); virtual;
    procedure TablePropToAggregate(
      aRecord: TOrm; aRecordProp: TOrmPropInfo;
      aAggregate: TObject; aAggregateProp: TOrmPropInfo); virtual;
    function GetAggregateRTTIOptions: TOrmPropInfoListOptions; virtual;
    // main IoC/DI method, returning a TDDDRepositoryRest instance
    function CreateInstance: TInterfacedObject; override;
        function TryResolve(aInterface: PRttiInfo; out Obj): boolean; override;
    function Implements(aInterface: PRttiInfo): boolean; override;

  public
    /// will compute the ORM TOrm* source code type definitions
    // corresponding to DDD aggregate objects into a a supplied file name
    // - will generate one TOrm* per aggregate class level, following the
    // inheritance hierarchy
    // - dedicated DDD types will be translated into native ORM types (e.g. RawUTF8)
    // - if no file name is supplied, it will generate a dddsqlrecord.inc file
    // in the executable folder
    // - could be used as such:
    // ! TDDDRepositoryRestFactory.ComputeSQLRecord([TPersonContactable,TAuthInfo]);
    // - once created, you may refine the ORM definition, by adding
    // ! ...  read f.... write f... stored AS_UNIQUE;
    // for fields which should be unique, and/or
    // ! ... read f... write f... index #;
    // to specify an optional textual field width (VARCHAR n) for SQL storage
    // - most advanced ORM-level filters/validators, or low-level implementation
    // details (like the Sqlite3 collation) may be added by overriding this method:
    // !protected
    // !  class procedure InternalDefineModel(Props: TOrmProperties); override;
    // ! ...
    // !class procedure TOrmMyAggregate.InternalDefineModel(
    // !  Props: TOrmProperties);
    // !begin
    // !  AddFilterNotVoidText(['HashedPassword']);
    // !  Props.SetCustomCollation('Field','BINARY');
    // !  Props.AddFilterOrValidate('Email',TSynValidateEmail.Create);
    // !end;
    class procedure ComputeSQLRecord(const aAggregate: array of TClass;
      DestinationSourceCodeFile: TFileName='');
    /// initialize the DDD Aggregate factory using a mORMot ORM class
    // - by default, field names should match on both sides - but you can
    // specify a custom field mapping as TOrm,Aggregate pairs
    // - any missing or unexpected field on any side will just be ignored
    constructor Create(
      const aInterface: TGUID; aImplementation: TDDDRepositoryRestClass;
      aAggregate: TClass; aRest: TRest; aTable: TOrmClass;
      const TableAggregatePairs: array of RawUTF8;
      aOwner: TDDDRepositoryRestManager=nil); reintroduce; overload;
    /// initialize the DDD Aggregate factory using a mORMot ORM class
    // - this overloaded constructor does not expect any custom fields
    // - any missing or unexpected field on any side will just be ignored
    constructor Create(
      const aInterface: TGUID; aImplementation: TDDDRepositoryRestClass;
      aAggregate: TClass; aRest: TRest; aTable: TOrmClass;
      aOwner: TDDDRepositoryRestManager=nil); reintroduce; overload;
    /// finalize the factory
    destructor Destroy; override;
    /// register a custom filter or validator to some Aggregate's fields
    // - once added, the TSynFilterOrValidate instance will be owned to
    // this factory, until it is released
    // - the field names should be named from their full path (e.g. 'Email' or
    // 'Address.Country.Iso') unless aFieldNameFlattened is TRUE, which will
    // expect ORM-like naming (e.g. 'Address_Country')
    // - if '*' is specified as field name, it will be applied to all text
    // fields, so the following will ensure that all text fields will be
    // trimmed for spaces:
    // !   AddFilterOrValidate(['*'],TSynFilterTrim.Create);
    // - filters and validators will be applied to a specified aggregate using
    // AggregateFilterAndValidate() method
    // - the same filtering classes as with the ORM can be applied to DDD's
    // aggregates, e.g. TSynFilterUpperCase, TSynFilterLowerCase or
    // TSynFilterTrim
    // - the same validation classes as with the ORM can be applied to DDD's
    // aggregates, e.g. TSynValidateText.Create for a void field,
    // TSynValidateText.Create('{MinLength:5}') for a more complex test
    // (including custom password strength validation if TSynValidatePassWord
    // is not enough), TSynValidateIPAddress.Create or TSynValidateEmail.Create
    // for some network settings, or TSynValidatePattern.Create()
    // - you should not define TSynValidateUniqueField here, which could't be
    // checked at DDD level, but rather set a "stored AS_UNIQUE" attribute
    // in the corresponding property of the TOrm type definition
    procedure AddFilterOrValidate(const aFieldNames: array of RawUTF8;
      aFilterOrValidate: TSynFilterOrValidate; aFieldNameFlattened: boolean=false); virtual;
    /// clear all properties of a given DDD Aggregate
    procedure AggregateClear(aAggregate: TObject);
    /// create a new DDD Aggregate instance
    function AggregateCreate: TObject; {$ifdef HASINLINE}inline;{$endif}
    /// perform filtering and validation on a supplied DDD Aggregate
    // - all logic defined by AddFilterOrValidate() will be processed
    function AggregateFilterAndValidate(aAggregate: TObject;
      aInvalidFieldIndex: PInteger=nil; aValidator: PSynValidate=nil): RawUTF8; virtual;
    /// serialize a DDD Aggregate as JSON
    // - you can optionaly force the generated JSON to match the mapped
    // TOrm fields, so that it would be compatible with ORM's JSON
    procedure AggregateToJSON(aAggregate: TObject; W: TJSONSerializer;
      ORMMappedFields: boolean; aID: TID); overload;
    /// serialize a DDD Aggregate as JSON RawUTF8
    function AggregateToJSON(aAggregate: TObject; ORMMappedFields: boolean;
      aID: TID): RawUTF8; overload;
    /// convert a DDD Aggregate into an ORM TOrm instance
    procedure AggregateToTable(aAggregate: TObject; aID: TID; aDest: TOrm);
    /// convert a ORM TOrm instance into a DDD Aggregate
    procedure AggregateFromTable(aSource: TOrm; aAggregate: TObject);
    /// convert ORM TOrm.FillPrepare instances into a DDD Aggregate ObjArray
    procedure AggregatesFromTableFill(aSource: TOrm; var aAggregateObjArray);
    /// the home repository owning this factory
    property Owner: TDDDRepositoryRestManager read fOwner;
    /// the DDD's Entity class handled by this factory
    // - may be any TPersistent, but very likely a TSynAutoCreateFields class
    property Aggregate: TClass read GetAggregateClass;
    /// the ORM's TOrm used for actual storage
    property Table: TOrmClass read fTable;
    /// the mapped DDD's Entity class published properties RTTI
    property Props: TOrmPropInfoList read fAggregateRTTI;
    /// access to the Aggregate / ORM field mapping
    property FieldMapping: TOrmPropertiesMapping read fPropsMapping;
  published
    /// the associated I*Query / I*Command repository interface
    property Repository: TInterfaceFactory read fInterface;
    /// the associated TRest instance
    property Rest: TRest read fRest;
    /// the DDD's Entity class name handled by this factory
    property AggregateClass: string read GetAggregateName;
    /// the ORM's TOrm class name used for actual storage
    property TableClass: string read GetTableName;
  end;

  /// abstract repository class to implement I*Query interface using RESTful ORM
  // - actual repository implementation will just call the ORM*() protected
  // method from the published Aggregate-oriented CQRS service interface
  TDDDRepositoryRestQuery = class(TCQRSService)
  protected
    fFactory: TDDDRepositoryRestFactory;
    fCurrentORMInstance: TOrm;
    function CqrsBeginMethod(aAction: TCQRSQueryAction; var aResult: TCQRSResult;
      aError: TCQRSResult=cqrsUnspecifiedError): boolean; override;
    // one-by-one retrieval in local ORM: TOrm
    function ORMSelectOne(const ORMWhereClauseFmt: RawUTF8;
      const Bounds: array of const; ForcedBadRequest: boolean=false): TCQRSResult;
    function ORMSelectID(const ID: TID; RetrieveRecord: boolean=true;
       ForcedBadRequest: boolean=false): TCQRSResult; overload;
    function ORMSelectID(const ID: RawUTF8; RetrieveRecord: boolean=true;
       ForcedBadRequest: boolean=false): TCQRSResult; overload;
    function ORMGetAggregate(aAggregate: TObject): TCQRSResult;
    // list retrieval - using cursor-like access via ORM.FillOne
    function ORMSelectAll(const ORMWhereClauseFmt: RawUTF8;
      const Bounds: array of const; ForcedBadRequest: boolean=false): TCQRSResult;
    function ORMGetNextAggregate(aAggregate: TObject; aRewind: boolean=false): TCQRSResult;
    function ORMGetAllAggregates(var aAggregateObjArray): TCQRSResult;
    function ORMSelectCount(const ORMWhereClauseFmt: RawUTF8; const Args,Bounds: array of const;
      out aResultCount: integer; ForcedBadRequest: boolean=false): TCQRSResult;
  public
    /// you should not have to use this constructor, since the instances would
    // be injected by TDDDRepositoryRestFactory.TryResolve()
    constructor Create(aFactory: TDDDRepositoryRestFactory); reintroduce; virtual;
    /// finalize the used memory
    destructor Destroy; override;
    /// return the number all currently selected aggregates
    // - returns 0 if no select was available, 1 if it was a ORMGetSelectOne(),
    // or the number of items after a ORMGetSelectAll()
    // - this is a generic operation which would work for any class
    // - if you do not need this method, just do not declare it in I*Command
    function GetCount: integer; virtual;
    /// returns the associated TRest instance used in the associated factory
    // - this method is able to extract it from a I*Query/I*Command instance,
    // if it is implemented by a TDDDRepositoryRestQuery class
    // - returns nil if the supplied Service is not recognized
    class function GetRest(const Service: ICQRSService): TRest;
  published
    /// access to the associated factory
    property Factory: TDDDRepositoryRestFactory read fFactory;
    /// access to the current state of the underlying mapped TOrm
    // - is nil if no query was run yet
    // - contains the queried object after a successful Select*() method
    // - is either a single object, or a list of objects, via its internal
    // CurrentORMInstance.FillTable cursor
    property CurrentORMInstance: TOrm read fCurrentORMInstance;
  end;

  /// abstract class to implement I*Command interface using ORM's TOrm
  // - it will use an internal TRestBatch for dual-phase commit, therefore
  // implementing a generic Unit Of Work / Transaction pattern
  TDDDRepositoryRestCommand = class(TDDDRepositoryRestQuery)
  protected
    fBatch: TRestBatch;
    fBatchAutomaticTransactionPerRow: cardinal;
    fBatchOptions: TRestBatchOptions;
    fBatchResults: TIDDynArray;
    procedure ORMEnsureBatchExists; virtual;
    // this default implementation will check the status vs command,
    // call DDD's + ORM's FilterAndValidate, then add to the internal BATCH
    // - you should override it, if you need a specific behavior
    // - if aAggregate is nil, fCurrentORMInstance field values would be used
    // - if aAggregate is set, its fields would be set to fCurrentORMInstance
    procedure ORMPrepareForCommit(aCommand: TOrmOccasion;
      aAggregate: TObject; var Result: TCQRSResult; aAllFields: boolean=false); virtual;
    /// minimal implementation using AggregateToTable() conversion
    function ORMAdd(aAggregate: TObject; aAllFields: boolean=false): TCQRSResult; virtual;
    function ORMUpdate(aAggregate: TObject; aAllFields: boolean=false): TCQRSResult; virtual;
    /// this default implementation will send the internal BATCH
    // - you should override it, if you need a specific behavior
    procedure InternalCommit(var Result: TCQRSResult); virtual;
    /// on rollback, delete the internal BATCH - called by Destroy
    procedure InternalRollback; virtual;
  public
    /// this constructor will set default fBatch options
    constructor Create(aFactory: TDDDRepositoryRestFactory); override;
    /// finalize the Unit Of Work context
    // - any uncommited change will be lost
    destructor Destroy; override;
    /// perform a deletion on the currently selected aggregate
    // - this is a generic operation which would work for any class
    // - if you do not need this method, just do not declare it in I*Command
    function Delete: TCQRSResult; virtual;
    /// perform a deletion on all currently selected aggregates
    // - this is a generic operation which would work for any class
    // - if you do not need this method, just do not declare it in I*Command
    function DeleteAll: TCQRSResult; virtual;
    /// write all pending changes prepared by Add/Update/Delete methods
    // - this is the only mandatory method, to be declared in your I*Command
    // - in practice, will send the current internal BATCH to the REST instance
    function Commit: TCQRSResult; virtual;
    /// flush any pending changes prepared by Add/Update/Delete methods
    // - if you do not need this method, just do not publish it in I*Command
    // - the easiest to perform a roll-back would be to release the I*Command
    // instance - but you may explictly reset the pending changes by calling
    // this method
    // - in practice, will release the internal BATCH instance
    function Rollback: TCQRSResult; virtual;
    /// access to the low-level BATCH instance, used for dual-phase commit
    // - you should not need to access it directly, but rely on Commit and
    // Rollback methods to
    property Batch: TRestBatch read fBatch;
  end;

  /// abstract CQRS class tied to a TSQLRest instance for low-level persistence
  // - not used directly by the DDD repositories (since they will rely on
  // a TDDDRepositoryRestFactory for the actual ORM process), but may be the
  // root class for any Rest-based infrastructure cross-cutting features
  TCQRSQueryObjectRest = class(TCQRSService)
  protected
    fRest: TRest;
  public
    /// this constructor would identify a TServiceContainer SOA resolver
    // and set the Rest property
    // - when called e.g. by TServiceFactoryServer.CreateInstance()
    constructor CreateWithResolver(aResolver: TInterfaceResolver;
      aRaiseEServiceExceptionIfNotFound: boolean); overload; override;
    /// reintroduced constructor, allowing to specify the associated REST instance
    constructor Create(aRest: TRest); reintroduce; virtual;
    /// reintroduced constructor, associating a REST instance with the supplied
    // IoC resolvers
    constructor CreateWithResolver(aRest: TRest; aResolver: TInterfaceResolver;
      aRaiseEServiceExceptionIfNotFound: boolean=true); reintroduce; overload;
    /// reintroduced constructor, associating a REST instance with the supplied
    // IoC resolvers (may be stubs/mocks, resolver classes or single instances)
    constructor CreateInjected(aRest: TRest;
      const aStubsByGUID: array of TGUID;
      const aOtherResolvers: array of TInterfaceResolver;
      const aDependencies: array of TInterfacedObject); reintroduce;
    /// access to the associated REST instance
    property Rest: TRest read FRest;
  end;

{ ----- Services / Daemon Implementation }

type
  TDDDMonitoredDaemon = class;

  /// the current state of a process thread
  TDDDMonitoredDaemonProcessState = (
    dpsPending, dpsProcessing, dpsProcessed, dpsFailed);

  /// abstract process thread class with monitoring abilities
  TDDDMonitoredDaemonProcess = class(TThread)
  protected
    fDaemon: TDDDMonitoredDaemon;
    fIndex: integer;
    fProcessIdleDelay: cardinal;
    fMonitoring: TSynMonitorWithSize;
    /// the main thread loop, which will call the protected Execute* methods
    procedure Execute; override;
  protected
    /// check for any pending task, and mark it as started
    // - will be executed within fDaemon.fProcessLock so that it would be
    // atomic among all fDaemon.fProcess[] threads - overriden implementation
    // should therefore ensure that this method executes as fast as possible
    // to minimize contention
    // - returns FALSE if there is no pending task
    // - returns TRUE if there is a pending task, and ExecuteProcessAndSetResult
    // should be called by Execute outside the fDaemon.fProcessLock
    function ExecuteRetrievePendingAndSetProcessing: boolean; virtual; abstract;
    /// execute the task, and set its resulting state
    // - resulting state may be e.g. "processed" or "failed"
    // - should return the number of bytes processed, for fMonitoring update
    // - will be executed outside fDaemon.fProcessLock so that overriden
    // implementation may take as much time as necessary for its process
    function ExecuteProcessAndSetResult: QWord;  virtual; abstract;
    /// finalize the pending task
    // - will always be called, even if ExecuteRetrievePendingAndSetProcessing
    // returned FALSE
    procedure ExecuteProcessFinalize; virtual; abstract;
    /// is called when there is no more pending task
    // - may be used e.g. to release a connection or some resource (e.g. an
    // ORM TRestBatch instance)
    procedure ExecuteIdle; virtual; abstract;
    /// will be called on any exception in Execute
    // - this default implementation will call fMonitoring.ProcessError()
    procedure ExecuteOnException(E: Exception); virtual;
  public
    /// initialize the process thread for a given Service/Daemon instance
    constructor Create(aDaemon: TDDDMonitoredDaemon; aIndexInDaemon: integer); virtual;
    /// finalize the process thread
    destructor Destroy; override;
    /// milliseconds delay defined before getting the next pending tasks
    // - equals TDDDMonitoredDaemon.ProcessIdleDelay, unless a fatal exception
    // occurred during TDDDMonitoredDaemonProcess.ExecuteIdle method: in this
    // case, the delay would been increased to 500 ms
    property IdleDelay: cardinal read fProcessIdleDelay;
  end;

  /// abstract process thread class with monitoring abilities, using the ORM
  // for pending tasks persistence
  // - a protected TSQLRecord instance will be maintained to store the
  // processing task and its current state
  TDDDMonitoredDaemonProcessRest = class(TDDDMonitoredDaemonProcess)
  protected
    /// the internal ORM instance used to maintain the current task
    // - it should contain the data to be processed, the processing state
    // (e.g. at least "processing", "processed" and "failed"), and optionally
    // the resulting content (if any)
    // - overriden ExecuteRetrievePendingAndSetProcessing method should create
    // fPendingTask then save fPendingTask.State to "processing"
    // - overriden ExecuteProcessAndSetResult method should perform the task,
    // then save fPendingTask.State to "processed" or "failed"
    fPendingTask: TOrm;
    /// finalize the pending task: will free fPendingTask and set it to nil
    procedure ExecuteProcessFinalize; override;
  end;


  /// class-reference type (metaclass) to determine which actual thread class
  // will implement the monitored process
  TDDDMonitoredDaemonProcessClass = class of TDDDMonitoredDaemonProcess;

  /// abstract class using several process threads and with monitoring abilities
  // - able to implement any DDD Daemon/Service, with proper statistics gathering
  // - each TDDDMonitoredDaemon will own its TDDDMonitoredDaemonProcess
  TDDDMonitoredDaemon = class(TCQRSQueryObjectRest,IMonitoredDaemon)
  protected
    fProcess: array of TDDDMonitoredDaemonProcess;
    fProcessClass: TDDDMonitoredDaemonProcessClass;
    fProcessMonitoringClass: TSynMonitorClass;
    fProcessLock: IAutoLocker;
    fProcessTimer: TPrecisionTimer;
    fProcessThreadCount: integer;
    fProcessIdleDelay: integer;
    fMonitoringClass: TSynMonitorClass;
    function GetStatus: variant; virtual;
  public
    /// abstract constructor, which should not be called by itself
    constructor Create(aRest: TRest); overload; override;
    /// you should override this constructor to set the actual process
    // - i.e. define the fProcessClass protected property
    constructor Create(aRest: TRest; aProcessThreadCount: integer); reintroduce; overload;
    /// finalize the Daemon
    destructor Destroy; override;
    /// monitor the Daemon/Service by returning some information as a TDocVariant
    // - its Status.stats sub object will contain global processing statistics,
    // and Status.threadstats similar information, detailled by running thread
    function RetrieveState(out Status: variant): TCQRSResult;
    /// launch all processing threads
    // - any previous running threads are first stopped
    function Start: TCQRSResult; virtual;
    /// finalize all processing threads
    // - and returns updated statistics as a TDocVariant
    function Stop(out Information: variant): TCQRSResult; virtual;
  published
    /// how many process threads should be created by this Daemon/Service
    property ProcessThreadCount: integer read fProcessThreadCount;
    /// how many milliseconds each process thread should wait before checking
    // for pending tasks
    // - default value is 50 ms, which seems good enough in practice
    property ProcessIdleDelay: integer read fProcessIdleDelay write fProcessIdleDelay;
  end;

implementation

uses
  mormot.db.core,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.unicode,
  mormot.core.datetime;

{ *********** Persistence / Repository Interfaces }

var
  TCQRSResultText: array[TCQRSResult] of PShortString;

function ToText(res: TCQRSResult): PShortString;
begin
  result := TCQRSResultText[res];
end;

function ToText(res: TCQRSQueryState): PShortString; overload;
begin
  result := GetEnumName(TypeInfo(TCQRSQueryState),ord(res));
end;


{ TCQRSService }

constructor TCQRSService.Create;
begin
  inherited Create;
  fSafe.Init;
  {$ifdef WITHLOG}
  fLog := SQLite3Log.Family; // may be overriden
  {$endif}
end;

function TCQRSService.GetLastError: TCQRSResult;
begin
  result := fLastError;
end;

function TCQRSService.GetLastErrorInfo: Variant;
begin
  result := fLastErrorContext;
end;

const
  NEEDS_QUERY   = [qaGet, qaCommandOnSelect];
  NEEDS_COMMAND = [qaCommit];
  ACTION_TO_STATE: array[TCQRSQueryAction] of TCQRSQueryState = (
    // qsNone = no state change after this action
    qsNone, qsQuery, qsNone, qsCommand, qsCommand, qsNone);

function TCQRSService.CqrsBeginMethod(aAction: TCQRSQueryAction;
  var aResult: TCQRSResult; aError: TCQRSResult): boolean;
begin
  aResult := aError;
  VarClear(fLastErrorContext);
  if (aAction in NEEDS_QUERY) and (fState<qsQuery) then begin
    CqrsSetResult(cqrsNoPriorQuery, aResult);
    result := false;
    exit;
  end;
  if (aAction in NEEDS_COMMAND) and (fState<qsCommand) then begin
    CqrsSetResult(cqrsNoPriorCommand, aResult);
    result := false;
    exit;
  end;
  fAction := aAction;
  result := true;
end;

function TCQRSService.CqrsSetResultError(aError: TCQRSResult): TCQRSResult;
begin
  CqrsBeginMethod(qaNone,result);
  CqrsSetResult(aError,result);
end;

procedure TCQRSService.CqrsSetResult(Error: TCQRSResult; var Result: TCQRSResult);
begin
  InternalCqrsSetResult(Error,Result);
  AfterInternalCqrsSetResult;
end;

function ObjectToVariantDebug(Value: TObject): variant; overload;
var json: RawUTF8;
begin
  VarClear(result);
  json := ObjectToJSONDebug(Value);
  PDocVariantData(@result)^.InitJSONInPlace(pointer(json),JSON_OPTIONS_FAST);
end;

procedure TCQRSService.CqrsSetResult(E: Exception; var Result: TCQRSResult);
begin
  InternalCqrsSetResult(cqrsInternalError,Result);
  _ObjAddProps(['Exception',ObjectToVariantDebug(E)],fLastErrorContext);
  AfterInternalCqrsSetResult;
end;

procedure TCQRSService.InternalCqrsSetResult(Error: TCQRSResult; var Result: TCQRSResult);
begin
  Result := Error;
  fLastError := Error;
  if Error<>cqrsSuccess then
    fLastErrorContext := ObjectToVariantDebug(self,'%',[NowToString]) else
    if ACTION_TO_STATE[fAction]<>qsNone then
      fState := ACTION_TO_STATE[fAction];
  fAction := qaNone;
end;

procedure TCQRSService.AfterInternalCqrsSetResult;
{$ifdef WITHLOG}
var
  level: TSynLogInfo;
{$endif}
begin
  {$ifdef WITHLOG}
  if fLastError in CQRSRESULT_SUCCESS then
    exit;
  if fLastError in CQRSRESULT_WARNING then
    level := sllDDDInfo else
    level := sllDDDError;
  if level in fLog.Level then
      fLog.SynLog.Log(level, 'CqrsSetResult(%) state=% %',
        [ToText(fLastError)^, ToText(fState)^, fLastErrorContext], self);
  {$endif}
end;

procedure TCQRSService.CqrsSetResultSuccessIf(SuccessCondition: boolean;
  var Result: TCQRSResult; ErrorIfFalse: TCQRSResult);
begin
  if SuccessCondition then
    CqrsSetResult(cqrsSuccess,Result) else
    CqrsSetResult(ErrorIfFalse,Result);
end;

procedure TCQRSService.CqrsSetResultDoc(Error: TCQRSResult; const ErrorInfo: variant;
  var Result: TCQRSResult);
begin
  InternalCqrsSetResult(Error,Result);
  _ObjAddProps(['ErrorInfo',ErrorInfo],fLastErrorContext);
  AfterInternalCqrsSetResult;
end;

procedure TCQRSService.CqrsSetResultJSON(Error: TCQRSResult;
  const JSONFmt: RawUTF8; const Args,Params: array of const; var Result: TCQRSResult);
begin
  CqrsSetResultDoc(Error,_JsonFastFmt(JSONFmt,Args,Params),Result);
end;

procedure TCQRSService.CqrsSetResultMsg(Error: TCQRSResult;
  const ErrorMessage: RawUTF8; var Result: TCQRSResult);
begin
  InternalCqrsSetResult(Error,Result);
  _ObjAddProps(['Msg',ErrorMessage],fLastErrorContext);
  AfterInternalCqrsSetResult;
end;

procedure TCQRSService.CqrsSetResultString(Error: TCQRSResult;
  const ErrorMessage: string; var Result: TCQRSResult);
begin
  InternalCqrsSetResult(Error,Result);
  _ObjAddProps(['Msg',ErrorMessage],fLastErrorContext);
  AfterInternalCqrsSetResult;
end;

procedure TCQRSService.CqrsSetResultMsg(Error: TCQRSResult;
  const ErrorMsgFmt: RawUTF8; const ErrorMsgArgs: array of const; var Result: TCQRSResult);
begin
  CqrsSetResultMsg(Error,FormatUTF8(ErrorMsgFmt,ErrorMsgArgs),Result);
end;

destructor TCQRSService.Destroy;
begin
  inherited Destroy;
  fSafe.Done;
end;


{ TCQRSServiceSubscribe }

procedure TCQRSServiceSubscribe.CallbackReleased(const callback: IInvokable;
  const interfaceName: RawUTF8);
var i: integer;
begin
  fSafe.Lock;
  try
    {$ifdef WITHLOG}
    fLog.SynLog.Log(sllTrace,'CallbackReleased(%,"%") callback=%',
      [callback,interfaceName,ObjectFromInterface(callback)],Self);
    {$endif}
    for i := 0 to high(fSubscriber) do // try to release on ALL subscribers
      fSubscriber[i].CallbackReleased(callback, interfaceName);
  finally
    fSafe.UnLock;
  end;
end;


{ TCQRSServiceSynch }

constructor TCQRSServiceSynch.Create(const sharedcallback: IInterface);
begin
  inherited Create;
  if sharedcallback = nil then
    raise EDDDException.CreateUTF8('%.Create(nil)', [self]);
  fSharedCallbackRef := sharedcallback;
end;


{ TCQRSServiceAsynchAck }

destructor TCQRSServiceAsynchAck.Destroy;
begin
  fCalls.Free; // would force evTimeOut if some WaitFor are still pending
  inherited Destroy;
end;

{ ----- Persistence / Repository Implementation using mORMot's ORM }

{ EDDDRepository }

constructor EDDDRepository.CreateUTF8(Caller: TDDDRepositoryRestFactory;
  const Format: RawUTF8; const Args: array of const);
begin
  if Caller=nil then
    inherited CreateUTF8(Format,Args) else
    inherited CreateUTF8('% - %',[FormatUTF8(Format,Args),ObjectToJSONDebug(Caller)]);
end;


{ TDDDRepositoryRestFactory }

constructor TDDDRepositoryRestFactory.Create(
  const aInterface: TGUID; aImplementation: TDDDRepositoryRestClass;
  aAggregate: TClass; aRest: TRest; aTable: TOrmClass;
  const TableAggregatePairs: array of RawUTF8; aOwner: TDDDRepositoryRestManager);
begin
  fInterface := TInterfaceFactory.Get(aInterface);
  if fInterface=nil then
    raise EDDDRepository.CreateUTF8(self,
     '%.Create(%): Interface not registered - you could use TInterfaceFactory.'+
     'RegisterInterfaces()',[self,GUIDToShort(aInterface)]);
  inherited Create(fInterface.InterfaceTypeInfo,aImplementation);
  fOwner := aOwner;
  fRest := aRest;
  fTable := aTable;
  if (aAggregate=nil) or (fRest=nil) or (fTable=nil) then
    raise EDDDRepository.CreateUTF8(self,'Invalid %.Create(nil)',[self]);
  fAggregate := Rtti.ByClass[aAggregate];
  fPropsMapping.Init(aTable,RawUTF8(aAggregate.ClassName),aRest,false,[]);
  fPropsMapping.MapFields(['ID','####']); // no ID/RowID for our aggregates
  fPropsMapping.MapFields(TableAggregatePairs);
  fAggregateRTTI := TOrmPropInfoList.Create(aAggregate, GetAggregateRTTIOptions);
  SetLength(fAggregateToTable,fAggregateRTTI.Count);
  SetLength(fAggregateProp,fAggregateRTTI.Count);
  ComputeMapping;
  {$ifdef WITHLOG}
  Rest.LogClass.Add.Log(sllDDDInfo,'Started % implementing % for % over %',
    [self,fInterface.InterfaceName,aAggregate,fTable],self);
  {$endif}
end;

constructor TDDDRepositoryRestFactory.Create(const aInterface: TGUID;
  aImplementation: TDDDRepositoryRestClass; aAggregate: TClass;
  aRest: TRest; aTable: TOrmClass;
  aOwner: TDDDRepositoryRestManager);
begin
  Create(aInterface,aImplementation,aAggregate,aRest,aTable,[],aOwner);
end;

function TDDDRepositoryRestFactory.GetAggregateRTTIOptions: TOrmPropInfoListOptions;
begin
  Result := [pilAllowIDFields,pilSubClassesFlattening,pilIgnoreIfGetter];
end;

destructor TDDDRepositoryRestFactory.Destroy;
begin
  {$ifdef WITHLOG}
  Rest.LogClass.Add.Log(sllDDDInfo,'Destroying %',[self],self);
  {$endif}
  fAggregateRTTI.Free;
  ObjArrayClear(fGarbageCollector);
  inherited;
end;

class procedure TDDDRepositoryRestFactory.ComputeSQLRecord(
  const aAggregate: array of TClass; DestinationSourceCodeFile: TFileName);
const RAW_TYPE: array[TOrmFieldType] of RawUTF8 = (
    // values left to '' will use the RTTI type
    '',                // sftUnknown
    'RawUTF8',         // sftAnsiText
    'RawUTF8',         // sftUTF8Text
    '',                // sftEnumerate
    '',                // sftSet
    '',                // sftInteger
    '',                // sftID = TOrm(aID)
    'TRecordReference',// sftRecord = TRecordReference
    'boolean',         // sftBoolean
    'double',          // sftFloat
    'TDateTime',       // sftDateTime
    'TTimeLog',        // sftTimeLog
    'currency',        // sftCurrency
    '',                // sftObject
    'variant',         // sftVariant
    '',                // sftNullable
    'TSQLRawBlob',     // sftBlob
    'variant',         // sftBlobDynArray T*ObjArray=JSON=variant (RawUTF8?)
    '',                // sftBlobCustom
    'variant',         // sftUTF8Custom
    '',                // sftMany
    'TModTime',        // sftModTime
    'TCreateTime',     // sftCreateTime
    '',                // sftTID
    'TRecordVersion',  // sftRecordVersion = TRecordVersion
    'TSessionUserID',  // sftSessionUserID
    '',                // sftDateTimeMS
    '',                // sftUnixTime
    '');               // sftUnixMSTime
var hier: TClassDynArray;
    a,i,f: integer;
    code,aggname,recname,parentrecname,typ: RawUTF8;
    map: TOrmPropInfoList;
    rectypes: TRawUTF8DynArray;
begin
  {$ifdef KYLIX3} hier := nil; {$endif to make compiler happy}
  if DestinationSourceCodeFile='' then
    DestinationSourceCodeFile := Executable.ProgramFilePath+'ddsqlrecord.inc';
  for a := 0 to high(aAggregate) do begin
    hier := ClassHierarchyWithField(aAggregate[a]);
    code := code+#13#10'type';
    parentrecname := 'TOrm';
    for i := 0 to high(hier) do begin
      aggname := RawUTF8(hier[i].ClassName);
      recname := 'TOrm'+copy(aggname,2,100);
      map := TOrmPropInfoList.Create(hier[i],
        [pilSingleHierarchyLevel,pilAllowIDFields,
         pilSubClassesFlattening,pilIgnoreIfGetter]);
      try
        code := FormatUTF8('%'#13#10+
          '  /// ORM class corresponding to % DDD aggregate'#13#10+
          '  % = class(%)'#13#10'  protected'#13#10,
          [code,aggname,recname,parentrecname]);
        SetLength(rectypes,map.count);
        for f := 0 to map.Count-1 do
        with map.List[f] do begin
          rectypes[f] := RAW_TYPE[OrmFieldType];
          if rectypes[f]='' then
            if OrmFieldType=oftInteger then begin
              rectypes[f] := 'Int64';
              if InheritsFrom(TOrmPropInfo) then
                with TOrmPropInfoRTTI(map.List[f]).PropType^ do
                  if (Kind=rkInteger) and (RttiOrd<>roULong) then
                    rectypes[f] := 'integer'; // cardinal -> Int64
            end else
              rectypes[f] := SQLFieldRTTITypeName;
          code := FormatUTF8('%    f%: %; // %'#13#10,
            [code,Name,rectypes[f],SQLFieldRTTITypeName]);
        end;
        code := code+'  published'#13#10;
        for f := 0 to map.Count-1 do
        with map.List[f] do begin
          typ := SQLFieldRTTITypeName;
          if IdemPropNameU(typ, rectypes[f]) then
            typ := '' else
            typ := ' ('+typ+')';
          code := FormatUTF8('%    /// maps %.%%'#13#10+
            '    property %: % read f% write f%;'#13#10, [code,aggname,
            NameUnflattened,typ,Name,rectypes[f],Name,Name]);
        end;
        code := code+'  end;'#13#10;
      finally
        map.Free;
      end;
      parentrecname := recname;
    end;
  end;
  FileFromString(code,DestinationSourceCodeFile);
end;

function TDDDRepositoryRestFactory.GetAggregateClass: TClass;
begin
  Result := fAggregate.ValueClass;
end;

procedure TDDDRepositoryRestFactory.ComputeMapping;

  procedure EnsureCompatible(agg,rec: TOrmPropInfo);
  { note about dynamic arrays (e.g. TRawUTF8DynArray or T*ObjArray) published fields:
      TOrder = class(TSynAutoCreateFields)
      published
        property Lines: TOrderLineObjArray
    In all cases, T*ObjArray should be accessible directly, using ObjArray*()
    wrapper functions, and other dynamic arrays too.
    Storage at TOrm level would use JSON format, i.e. a variant in the
    current implementation - you may use a plain RawUTF8 field if the on-the-fly
    conversion to/from TDocVariant appears to be a bottleneck. }
  begin
    if agg.SQLDBFieldType=rec.SQLDBFieldType then
      exit; // very same type at DB level -> OK
    if (agg.OrmFieldType=oftBlobDynArray) and
       (rec.OrmFieldType in [oftVariant,oftUTF8Text]) then
      exit; // allow array <-> JSON/TEXT <-> variant/RawUTF8 marshalling
    raise EDDDRepository.CreateUTF8(self,
      '% types do not match at DB level: %.%:%=% and %.%:%=%',[self,
      Aggregate,agg.Name,agg.SQLFieldRTTITypeName,agg.SQLDBFieldTypeName^,
      fTable,rec.Name,rec.SQLFieldRTTITypeName,rec.SQLDBFieldTypeName^]);
  end;

var i,ndx: integer;
    ORMProps: TOrmPropInfoObjArray;
    agg: TOrmPropInfoRTTI;
begin
  fAggregateID := nil;
  ORMProps := fTable.OrmProps.Fields.List;
  for i := 0 to fAggregateRTTI.Count-1 do begin
    agg := fAggregateRTTI.List[i] as TOrmPropInfoRTTI;
    fAggregateProp[i] := agg;
    ndx := fPropsMapping.ExternalToInternalIndex(agg.Name);
    if ndx=-1 then // ID/RowID mapped with an existing String/Hexa field
      if agg.SQLDBFieldType in [ftInt64,ftUTF8] then begin
        fAggregateID := agg;
        fAggregateToTable[i] := nil;
      end else
        raise EDDDRepository.CreateUTF8(self,'% types error: %.%:%=% and %.RowID',
          [self,Aggregate,agg.Name,agg.SQLFieldRTTITypeName,agg.SQLDBFieldTypeName^,fTable]) else
    if ndx<0 then // e.g. TSynPersistent property flattened in TOrm
      fAggregateToTable[i] := nil else begin
      fAggregateToTable[i] := ORMProps[ndx];
      EnsureCompatible(agg,fAggregateToTable[i]);
    end;
  end;
  fPropsMappingVersion := fPropsMapping.MappingVersion;
end;

procedure TDDDRepositoryRestFactory.AggregatePropToTable(
  aAggregate: TObject; aAggregateProp: TOrmPropInfo;
  aRecord: TOrm; aRecordProp: TOrmPropInfo);

  procedure ProcessID;
  var v: RawUTF8;
      id: TID;
  begin
    fAggregateID.GetValueVar(aAggregate,false,v,nil);
    case fAggregateID.SQLDBFieldType of
    ftInt64:
      SetID(pointer(v),id);
    ftUTF8:
      if not HexDisplayToBin(pointer(v),@id,sizeof(id)) then
        id := 0;
    end;
    aRecord.IDValue := id;
  end;

begin
  if fAggregateID=aAggregateProp then
    ProcessID else
    if aRecordProp<>nil then
      aAggregateProp.CopyProp(aAggregate,aRecordProp,aRecord);
end;

procedure TDDDRepositoryRestFactory.TablePropToAggregate(
  aRecord: TOrm; aRecordProp: TOrmPropInfo; aAggregate: TObject;
  aAggregateProp: TOrmPropInfo);

  procedure ProcessID;
  var v: RawUTF8;
  begin
    case fAggregateID.SQLDBFieldType of
    ftInt64: begin
      Int64ToUtf8(aRecord.IDValue,v);
      fAggregateID.SetValue(aAggregate,pointer(v),Length(v),false);
    end;
    ftUTF8: begin
      Int64ToHex(aRecord.IDValue,v);
      fAggregateID.SetValue(aAggregate,pointer(v),Length(v),true);
    end;
    end;
  end;

begin
  if fAggregateID=aAggregateProp then
    ProcessID else
    if aRecordProp=nil then
      aAggregateProp.SetValue(AAggregateProp.Flattened(aAggregate),nil,0,false) else
      aRecordProp.CopyProp(aRecord,aAggregateProp,aAggregate);
end;

function TDDDRepositoryRestFactory.CreateInstance: TInterfacedObject;
begin
  result := TDDDRepositoryRestClass(fImplementation.ValueClass).Create(self);
end;

function TDDDRepositoryRestFactory.TryResolve(aInterface: PRttiInfo; out Obj): boolean;
begin
  Result := inherited TryResolve(aInterface, Obj);
end;

function TDDDRepositoryRestFactory.Implements(aInterface: PRttiInfo): boolean;
begin
  Result := inherited Implements(aInterface);
end;

procedure TDDDRepositoryRestFactory.AggregateClear(aAggregate: TObject);
var i: integer;
begin
  if aAggregate<>nil then
    for i := 0 to high(fAggregateProp) do
      with fAggregateProp[i] do
        SetValue(Flattened(aAggregate),nil,0,false);
end;

function TDDDRepositoryRestFactory.AggregateCreate: TObject;
begin
  result := fAggregate.ClassNewInstance;
end;

procedure TDDDRepositoryRestFactory.AggregateToJSON(aAggregate: TObject;
  W: TJSONSerializer; ORMMappedFields: boolean; aID: TID);
var i: integer;
begin
  if fPropsMapping.MappingVersion<>fPropsMappingVersion then
    ComputeMapping;
  if aAggregate=nil then begin
    W.AddShort('null');
    exit;
  end;
  W.Add('{');
  if aID<>0 then begin
    W.AddShort('"RowID":');
    W.Add(aID);
    W.Add(',');
  end;
  for i := 0 to high(fAggregateProp) do begin
    if ORMMappedFields then
      if fAggregateToTable[i]=nil then
        continue else
        W.AddFieldName(fAggregateToTable[i].Name) else
        W.AddFieldName(fAggregateProp[i].Name);
    with fAggregateProp[i] do
      GetJSONValues(Flattened(aAggregate),W);
    W.Add(',');
  end;
  W.CancelLastComma;
  W.Add('}');
end;

function TDDDRepositoryRestFactory.AggregateToJSON(
  aAggregate: TObject; ORMMappedFields: boolean; aID: TID): RawUTF8;
var W: TJSONSerializer;
begin
  if aAggregate=nil then begin
    result := 'null';
    exit;
  end;
  W := TJSONSerializer.CreateOwnedStream;
  try
    AggregateToJSON(aAggregate,W,ORMMappedFields,aID);
    W.SetText(result);
  finally
    W.Free;
  end;
end;

procedure TDDDRepositoryRestFactory.AggregateToTable(
  aAggregate: TObject; aID: TID; aDest: TOrm);
var i: integer;
begin
  if fPropsMapping.MappingVersion<>fPropsMappingVersion then
    ComputeMapping;
  if aDest=nil then
    raise EDDDRepository.CreateUTF8(self,'%.AggregateToTable(%,%,%=nil)',
      [self,aAggregate,aID,fTable]);
  aDest.ClearProperties;
  aDest.IDValue := aID;
  if aAggregate<>nil then
    for i := 0 to length(fAggregateProp)-1 do
      AggregatePropToTable(aAggregate,fAggregateProp[i],aDest,fAggregateToTable[i]);
end;

procedure TDDDRepositoryRestFactory.AggregateFromTable(
  aSource: TOrm; aAggregate: TObject);
var i: integer;
begin
  if fPropsMapping.MappingVersion<>fPropsMappingVersion then
    ComputeMapping;
  if aAggregate=nil then
    raise EDDDRepository.CreateUTF8(self,'%.AggregateFromTable(%=nil)',[self,Aggregate]);
  if aSource=nil then
    AggregateClear(aAggregate) else
    for i := 0 to length(fAggregateProp)-1 do
      TablePropToAggregate(aSource,fAggregateToTable[i],aAggregate,fAggregateProp[i]);
end;

procedure TDDDRepositoryRestFactory.AggregatesFromTableFill(
  aSource: TOrm; var aAggregateObjArray);
var res: TObjectDynArray absolute aAggregateObjArray;
    i: integer;
begin
  SetLength(res, aSource.FillTable.RowCount);
  i := 0;
  if aSource.FillRewind then
    while aSource.FillOne do begin
      res[i] := fAggregate.ClassNewInstance;
      AggregateFromTable(aSource,res[i]);
      inc(i);
    end;
  if i <> length(res) then
    ObjArrayClear(res);
end;

function TDDDRepositoryRestFactory.GetAggregateName: string;
begin
  if (self=nil) or (Aggregate=nil) then
    result := '' else
    result := string(Aggregate.ClassName);
end;

function TDDDRepositoryRestFactory.GetTableName: string;
begin
  if (self=nil) or (fTable=nil) then
    result := '' else
    result := fTable.ClassName;
end;

procedure TDDDRepositoryRestFactory.AddFilterOrValidate(
  const aFieldNames: array of RawUTF8; aFilterOrValidate: TSynFilterOrValidate;
  aFieldNameFlattened: boolean);
var f,ndx: integer;
    arr: ^TPointerDynArray;
begin
  if aFilterOrValidate=nil then
    exit;
  ObjArrayAdd(fGarbageCollector,aFilterOrValidate);
  for f := 0 to high(aFieldNames) do begin
    if aFilterOrValidate.InheritsFrom(TSynValidate) then
      arr := @fValidate else
      arr := @fFilter;
    if arr^=nil then
      SetLength(arr^,fAggregateRTTI.Count);
    if aFieldNames[f]='*' then begin // apply to all text fields
      for ndx := 0 to high(fAggregateProp) do
        if fAggregateProp[ndx].OrmFieldType in RAWTEXT_FIELDS then
          aFilterOrValidate.AddOnce(TSynFilterOrValidateObjArray(arr^[ndx]),false);
    end else begin
      if aFieldNameFlattened then
        ndx := fAggregateRTTI.IndexByNameUnflattenedOrExcept(aFieldNames[f]) else
        ndx := fAggregateRTTI.IndexByNameOrExcept(aFieldNames[f]);
      aFilterOrValidate.AddOnce(TSynFilterOrValidateObjArray(arr^[ndx]),false);
    end;
  end;
end;

function TDDDRepositoryRestFactory.AggregateFilterAndValidate(
  aAggregate: TObject; aInvalidFieldIndex: PInteger; aValidator: PSynValidate): RawUTF8;
var f,i: integer;
    Value: TRawUTF8DynArray; // avoid twice retrieval
    Old: RawUTF8;
    msg: string;
    str: boolean;
begin
  if (aAggregate=nil) or not aAggregate.ClassType.InheritsFrom(Aggregate) then
    raise EDDDRepository.CreateUTF8(self,'%.AggregateFilterAndValidate(%) '+
      'expects a % instance',[self,aAggregate,Aggregate]);
  // first process all filters
  SetLength(Value,fAggregateRTTI.Count);
  for f := 0 to high(fFilter) do
    if fFilter[f]<>nil then begin
      with fAggregateProp[f] do
        GetValueVar(Flattened(aAggregate),false,Value[f],@str);
      Old := Value[f];
      for i := 0 to high(fFilter[f]) do
        fFilter[f,i].Process(f,Value[f]);
      if Old<>Value[f] then
        with fAggregateProp[f] do
          SetValueVar(Flattened(aAggregate),Value[f],str);
    end;
  // then validate the content
  for f := 0 to high(fValidate) do
    if fValidate[f]<>nil then begin
      if Value[f]='' then // if not already retrieved
        with fAggregateProp[f] do
          GetValueVar(Flattened(aAggregate),false,Value[f],nil);
      for i := 0 to high(fValidate[f]) do
        if not fValidate[f,i].Process(f,Value[f],msg) then begin
          if aInvalidFieldIndex<>nil then
            aInvalidFieldIndex^ := f;
          if aValidator<>nil then
            aValidator^ := fValidate[f,i];
          if msg='' then
            // no custom message -> show a default message
            msg := format(sValidationFailed,[GetCaptionFromClass(fValidate[f,i].ClassType)]);
          result := FormatUTF8('%.%: %',[Aggregate,fAggregateProp[f].NameUnflattened,msg]);
          exit;
        end;
    end;
  result := ''; // if we reached here, there was no error
end;



{ TDDDRepositoryRestManager }

function TDDDRepositoryRestManager.AddFactory(const aInterface: TGUID; aImplementation: TDDDRepositoryRestClass; aAggregate: TClass; aRest: TRest; aTable: TOrmClass; const TableAggregatePairs: array of RawUTF8): TDDDRepositoryRestFactory;
begin
  if GetFactoryIndex(aInterface)>=0 then
    raise EDDDRepository.CreateUTF8(nil,'Duplicated GUID for %.AddFactory(%,%,%)',
      [self,GUIDToShort(aInterface),aImplementation,aAggregate]);
  result := TDDDRepositoryRestFactory.Create(
    aInterface,aImplementation,aAggregate,aRest,aTable,TableAggregatePairs,self);
  ObjArrayAdd(fFactory,result);
  {$ifdef WITHLOG}
  aRest.LogClass.Add.Log(sllDDDInfo,'Added factory % to %',[result,self],self);
  {$endif}
end;

destructor TDDDRepositoryRestManager.Destroy;
begin
  ObjArrayClear(fFactory);
  inherited;
end;

function TDDDRepositoryRestManager.GetFactory(
  const aInterface: TGUID): TDDDRepositoryRestFactory;
var i: integer;
begin
  i := GetFactoryIndex(aInterface);
  if i<0 then
    raise EDDDRepository.CreateUTF8(nil,'%.GetFactory(%)=nil',
      [self,GUIDToShort(aInterface)]);
  result := fFactory[i];
end;

function TDDDRepositoryRestManager.GetFactoryIndex(
  const aInterface: TGUID): integer;
begin
  for result := 0 to length(fFactory)-1 do
    if IsEqualGUID(@fFactory[result].fInterface.InterfaceIID,@aInterface) then
      exit;
  result := -1;
end;


{ TDDDRepositoryRestQuery }

constructor TDDDRepositoryRestQuery.Create(
  aFactory: TDDDRepositoryRestFactory);
begin
  inherited Create;
  fFactory := aFactory;
  fCurrentORMInstance := fFactory.Table.Create;
  {$ifdef WITHLOG}
  fLog := fFactory.Rest.LogFamily;
  {$endif}
end;

destructor TDDDRepositoryRestQuery.Destroy;
begin
  fCurrentORMInstance.Free;
  inherited;
end;

class function TDDDRepositoryRestQuery.GetRest(const Service: ICQRSService): TRest;
var instance: TObject;
begin
  instance := ObjectFromInterface(Service);
  if (instance=nil) or not instance.InheritsFrom(TDDDRepositoryRestQuery) then
    result := nil else
    result := TDDDRepositoryRestQuery(instance).fFactory.fRest;
end;

function TDDDRepositoryRestQuery.CqrsBeginMethod(aAction: TCQRSQueryAction;
  var aResult: TCQRSResult; aError: TCQRSResult): boolean;
begin
  result := inherited CqrsBeginMethod(aAction,aResult,aError);
  if aAction=qaSelect then
    fCurrentORMInstance.ClearProperties; // reset internal instance
end;

function TDDDRepositoryRestQuery.ORMSelectOne(const ORMWhereClauseFmt: RawUTF8;
  const Bounds: array of const; ForcedBadRequest: boolean): TCQRSResult;
begin
  CqrsBeginMethod(qaSelect,result);
  if ForcedBadRequest then
    CqrsSetResult(cqrsBadRequest,result) else
    CqrsSetResultSuccessIf(Factory.Rest.Orm.Retrieve(ORMWhereClauseFmt,[],Bounds,
      fCurrentORMInstance),result,cqrsNotFound);
end;

function TDDDRepositoryRestQuery.ORMSelectID(const ID: TID;
  RetrieveRecord, ForcedBadRequest: boolean): TCQRSResult;
begin
  CqrsBeginMethod(qaSelect,result);
  if ForcedBadRequest or (ID=0) then
    CqrsSetResult(cqrsBadRequest,result) else
  if RetrieveRecord then
    CqrsSetResultSuccessIf(Factory.Rest.Orm.Retrieve(ID,fCurrentORMInstance),result,cqrsNotFound)
  else begin
    fCurrentORMInstance.IDValue := ID;
    CqrsSetResult(cqrsSuccess,result);
  end
end;

function TDDDRepositoryRestQuery.ORMSelectID(const ID: RawUTF8;
  RetrieveRecord, ForcedBadRequest: boolean): TCQRSResult;
begin
  result := ORMSelectID(HexDisplayToInt64(ID),RetrieveRecord,ForcedBadRequest);
end;

function TDDDRepositoryRestQuery.ORMSelectAll(
  const ORMWhereClauseFmt: RawUTF8; const Bounds: array of const;
  ForcedBadRequest: boolean): TCQRSResult;
begin
  CqrsBeginMethod(qaSelect,result);
  if ForcedBadRequest then
    CqrsSetResult(cqrsBadRequest,result) else
    CqrsSetResultSuccessIf(fCurrentORMInstance.FillPrepare(
      Factory.Rest.Orm,ORMWhereClauseFmt,[],Bounds),result,cqrsNotFound);
end;

function TDDDRepositoryRestQuery.ORMSelectCount(
  const ORMWhereClauseFmt: RawUTF8; const Args,Bounds: array of const;
  out aResultCount: integer; ForcedBadRequest: boolean): TCQRSResult;
var tmp: Int64;
begin
  CqrsBeginMethod(qaNone,result); // qaNone and not qaSelect which would fill ORM
  if ForcedBadRequest then
    CqrsSetResult(cqrsBadRequest,result) else
    if Factory.Rest.Orm.OneFieldValue(
        Factory.Table,'count(*)',ORMWhereClauseFmt,Args,Bounds,tmp) then begin
       aResultCount := tmp;
       CqrsSetResult(cqrsSuccess,result)
    end else
      CqrsSetResult(cqrsNotFound,result);
end;

function TDDDRepositoryRestQuery.GetCount: integer;
var dummy: TCQRSResult;
begin
  if not CqrsBeginMethod(qaGet,dummy) then
    result := 0 else
    if fCurrentORMInstance.FillTable<>nil then
      result := fCurrentORMInstance.FillTable.RowCount else
      if fCurrentORMInstance.IDValue=0 then
        result := 0 else
        result := 1;
end;

function TDDDRepositoryRestQuery.ORMGetAggregate(
  aAggregate: TObject): TCQRSResult;
begin
  if CqrsBeginMethod(qaGet,result) then begin
    Factory.AggregateFromTable(fCurrentORMInstance,aAggregate);
    CqrsSetResult(cqrsSuccess,result);
  end;
end;

function TDDDRepositoryRestQuery.ORMGetNextAggregate(
  aAggregate: TObject; aRewind: boolean): TCQRSResult;
begin
  if CqrsBeginMethod(qaGet,result) then
    if (aRewind and fCurrentORMInstance.FillRewind) or
       (not aRewind and fCurrentORMInstance.FillOne) then begin
      Factory.AggregateFromTable(fCurrentORMInstance,aAggregate);
      CqrsSetResult(cqrsSuccess,result);
    end else
      CqrsSetResult(cqrsNoMoreData,result);
end;

function TDDDRepositoryRestQuery.ORMGetAllAggregates(
  var aAggregateObjArray): TCQRSResult;
begin
  if CqrsBeginMethod(qaGet,result) then
  if (fCurrentORMInstance.FillTable=nil) or
     (fCurrentORMInstance.FillTable.RowCount=0) then
    CqrsSetResult(cqrsSuccess,result) else begin
    Factory.AggregatesFromTableFill(fCurrentORMInstance,aAggregateObjArray);
    if Pointer(aAggregateObjArray)=nil then
      CqrsSetResult(cqrsNoMoreData,result) else
      CqrsSetResult(cqrsSuccess,result);
  end;
end;



{ TDDDRepositoryRestCommand }

constructor TDDDRepositoryRestCommand.Create(
  aFactory: TDDDRepositoryRestFactory);
begin
  inherited Create(aFactory);
  fBatchAutomaticTransactionPerRow := 1000; // for better performance
  fBatchOptions := [boExtendedJSON];
end;

destructor TDDDRepositoryRestCommand.Destroy;
begin
  InternalRollback;
  inherited Destroy;
end;

function TDDDRepositoryRestCommand.Delete: TCQRSResult;
begin
  if CqrsBeginMethod(qaCommandOnSelect,result) then
    ORMPrepareForCommit(ooDelete,nil,result);
end;

function TDDDRepositoryRestCommand.DeleteAll: TCQRSResult;
var i: integer;
begin
  if CqrsBeginMethod(qaCommandOnSelect,result) then
    if fCurrentORMInstance.FillTable=nil then
      ORMPrepareForCommit(ooDelete,nil,result) else
      if fState<qsQuery then
        CqrsSetResult(cqrsNoPriorQuery,result) else begin
        ORMEnsureBatchExists;
        for i := 1 to fCurrentORMInstance.FillTable.RowCount do
          if fBatch.Delete(fCurrentORMInstance.FillTable.GetID(i))<0 then begin
            CqrsSetResult(cqrsDataLayerError,result);
            exit;
          end;
        CqrsSetResult(cqrsSuccess,result);
      end;
end;

function TDDDRepositoryRestCommand.ORMAdd(aAggregate: TObject;
  aAllFields: boolean): TCQRSResult;
begin
  if CqrsBeginMethod(qaCommandDirect,result) then
    ORMPrepareForCommit(ooInsert,aAggregate,result,aAllFields);
end;

function TDDDRepositoryRestCommand.ORMUpdate(aAggregate: TObject;
  aAllFields: boolean): TCQRSResult;
begin
  if CqrsBeginMethod(qaCommandOnSelect,result) then
    ORMPrepareForCommit(ooUpdate,aAggregate,result,aAllFields);
end;

procedure TDDDRepositoryRestCommand.ORMEnsureBatchExists;
begin
  if fBatch=nil then
    fBatch := TRestBatch.Create(Factory.Rest.Orm,Factory.Table,
      fBatchAutomaticTransactionPerRow,fBatchOptions);
end;

procedure TDDDRepositoryRestCommand.ORMPrepareForCommit(
  aCommand: TOrmOccasion; aAggregate: TObject; var Result: TCQRSResult;
  aAllFields: boolean);
var msg: RawUTF8;
    validator: TSynValidate;
    ndx: integer;
    fields: TFieldBits;

  procedure SetValidationError(default: TCQRSResult);
  begin
    if (validator<>nil) and
       (validator.ClassType=TSynValidateUniqueField) then
      CqrsSetResultMsg(cqrsAlreadyExists,msg,Result) else
      CqrsSetResultMsg(default,msg,Result);
  end;

begin
  case aCommand of
  ooSelect: begin
    CqrsSetResult(cqrsBadRequest,Result);
    exit;
  end;
  ooUpdate,ooDelete:
    if (fState<qsQuery) or (fCurrentORMInstance.IDValue=0) then begin
      CqrsSetResult(cqrsNoPriorQuery,Result);
      exit;
    end;
  end;
  if aCommand in [ooUpdate,ooInsert] then begin
    if aAggregate<>nil then begin
      msg := Factory.AggregateFilterAndValidate(aAggregate,nil,@validator);
      if msg<>'' then begin
        SetValidationError(cqrsDDDValidationFailed);
        exit;
      end;
      Factory.AggregateToTable(aAggregate,fCurrentORMInstance.IDValue,fCurrentORMInstance);
    end;
    msg := fCurrentORMInstance.FilterAndValidate(
      Factory.Rest.Orm,[0..MAX_SQLFIELDS-1],@validator);
    if msg<>'' then begin
      SetValidationError(cqrsDataLayerError);
      exit;
    end;
  end;
  ORMEnsureBatchExists;
  ndx := -1;
  if aAllFields then
    fields := ALL_FIELDS else
    fields := [];
  case aCommand of
  ooInsert: ndx := fBatch.Add(fCurrentORMInstance,true,fFactory.fAggregateID<>nil,fields);
  ooUpdate: ndx := fBatch.Update(fCurrentORMInstance,fields);
  ooDelete: ndx := fBatch.Delete(fCurrentORMInstance.IDValue);
  end;
  CqrsSetResultSuccessIf(ndx>=0,Result);
end;

procedure TDDDRepositoryRestCommand.InternalCommit(var Result: TCQRSResult);
begin
  if fBatch.Count=0 then
    CqrsSetResult(cqrsBadRequest,Result) else begin
    CqrsSetResultSuccessIf(Factory.Rest.Orm.BatchSend(fBatch,fBatchResults)=HTTP_SUCCESS,Result);
    FreeAndNil(fBatch);
  end;
end;

procedure TDDDRepositoryRestCommand.InternalRollback;
begin
  FreeAndNil(fBatch);
  fBatchResults := nil;
end;

function TDDDRepositoryRestCommand.Commit: TCQRSResult;
begin
  if CqrsBeginMethod(qaCommit,result) then
    InternalCommit(result);
end;

function TDDDRepositoryRestCommand.Rollback: TCQRSResult;
begin
  CqrsBeginMethod(qaNone,result,cqrsSuccess);
  if fBatch.Count=0 then
    CqrsSetResult(cqrsNoPriorCommand,result) else
    InternalRollback;
end;

{ TCQRSQueryObjectRest }

constructor TCQRSQueryObjectRest.Create(aRest: TRest);
begin
  fRest := aRest;
  if (fResolver<>nil) or (aRest=nil) or (aRest.Services=nil) then
    inherited Create else
    inherited CreateWithResolver(aRest.Services);
end;

constructor TCQRSQueryObjectRest.CreateInjected(aRest: TRest;
  const aStubsByGUID: array of TGUID;
  const aOtherResolvers: array of TInterfaceResolver;
  const aDependencies: array of TInterfacedObject);
begin
  if not Assigned(aRest) then
    raise ECQRSException.CreateUTF8('%.CreateInjected(Rest=nil)',[self]);
  Create(aRest);
  inherited CreateInjected(aStubsByGUID,aOtherResolvers,
    aDependencies,true);
end;

constructor TCQRSQueryObjectRest.CreateWithResolver(aRest: TRest;
  aResolver: TInterfaceResolver; aRaiseEServiceExceptionIfNotFound: boolean);
begin
  if not Assigned(aRest) then
    raise ECQRSException.CreateUTF8('%.CreateWithResolver(Rest=nil)',[self]);
  fRest := aRest;
  inherited CreateWithResolver(aResolver,aRaiseEServiceExceptionIfNotFound);
end;

constructor TCQRSQueryObjectRest.CreateWithResolver(
  aResolver: TInterfaceResolver; aRaiseEServiceExceptionIfNotFound: boolean);
begin
  if (aResolver<>nil) and aResolver.InheritsFrom(TServiceContainer) then
    fRest := TServiceContainer(aResolver).Owner as TRest;
  inherited CreateWithResolver(aResolver,aRaiseEServiceExceptionIfNotFound);
end;

{ TDDDMonitoredDaemonProcess }

constructor TDDDMonitoredDaemonProcess.Create(aDaemon: TDDDMonitoredDaemon;
  aIndexInDaemon: integer);
begin
  fDaemon := aDaemon;
  if fDaemon.fProcessMonitoringClass=nil then
    fMonitoring := TSynMonitorWithSize.Create(aDaemon.Rest.Model.Root) else
    fMonitoring := fDaemon.fProcessMonitoringClass.Create(aDaemon.Rest.Model.Root)
      as TSynMonitorWithSize;
  fProcessIdleDelay := fDaemon.ProcessIdleDelay;
  fIndex := aIndexInDaemon;
  inherited Create(False);
end;

destructor TDDDMonitoredDaemonProcess.Destroy;
begin
  fMonitoring.Free;
  inherited;
end;

procedure TDDDMonitoredDaemonProcess.Execute;
begin
  fDaemon.Rest.Run.BeginCurrentThread(self);
  try
    repeat
      SleepHiRes(fProcessIdleDelay);
      try
        try
          repeat
            if Terminated then
              exit;
            try
              try
                fDaemon.fProcessLock.Enter; // atomic unqueue via pending.Status
                try
                  fMonitoring.ProcessStart;
                  if not ExecuteRetrievePendingAndSetProcessing then
                    break; // no more pending tasks
                  fMonitoring.ProcessDoTask;
                finally
                  fDaemon.fProcessLock.Leave;
                end;
                // always set, even if Terminated
                fMonitoring.AddSize(ExecuteProcessAndSetResult);
              finally
                fMonitoring.ProcessEnd;
                ExecuteProcessFinalize;
              end;
            except
              on E: Exception do begin
                ExecuteOnException(E);
                break; // will call ExecuteIdle then go to idle state
              end;
            end;
          until false;
        finally
          ExecuteIdle;
        end;
      except
        on E: Exception do begin
          ExecuteOnException(E); // exception during ExecuteIdle should not happen
          if fProcessIdleDelay<500 then
            fProcessIdleDelay := 500; // avoid CPU+resource burning
        end;
      end;
    until false;
  finally
    fDaemon.Rest.Run.EndCurrentThread(self);
  end;
end;

procedure TDDDMonitoredDaemonProcess.ExecuteOnException(E: Exception);
begin
  fMonitoring.ProcessError(ObjectToVariantDebug(
    E,'{threadindex:?,daemon:?}',[fIndex,fDaemon.GetStatus]));
end;


{ TDDDMonitoredDaemonProcessRest }

procedure TDDDMonitoredDaemonProcessRest.ExecuteProcessFinalize;
begin
  FreeAndNil(fPendingTask);
end;


{ TDDDMonitoredDaemon }

constructor TDDDMonitoredDaemon.Create(aRest: TRest);
begin
  fProcessIdleDelay := 50;
  fProcessLock := TAutoLocker.Create;
  if fProcessThreadCount<1 then
    fProcessThreadCount := 1 else
  if fProcessThreadCount>20 then
    fProcessThreadCount := 20;
  inherited Create(aRest);
end;

constructor TDDDMonitoredDaemon.Create(aRest: TRest;
  aProcessThreadCount: integer);
begin
  fProcessThreadCount := aProcessThreadCount;
  Create(aRest);
end;

destructor TDDDMonitoredDaemon.Destroy;
var dummy: variant;
begin
  Stop(dummy);
  inherited Destroy;
end;

function TDDDMonitoredDaemon.GetStatus: variant;
var i,working: integer;
    stats: TSynMonitor;
    pool: TDocVariantData;
begin
  {$ifdef WITHLOG}
  Rest.LogClass.Enter('GetStatus',[],self);
  {$endif}
  VarClear(result);
  fProcessLock.Enter;
  try
    try
      working := 0;
      if fMonitoringClass=nil then
        if fProcessMonitoringClass=nil then
          stats := TSynMonitorWithSize.Create else
          stats := fProcessMonitoringClass.Create else
        stats := fMonitoringClass.Create;
      try
        pool.InitArray([],JSON_OPTIONS[true]);
        for i := 0 to High(fProcess) do
        with fProcess[i] do begin

          if fMonitoring.Processing then
            inc(working);
          pool.AddItem(fMonitoring.ComputeDetails);
          stats.Sum(fMonitoring);
        end;
        result := ObjectToVariantDebug(self);
        _ObjAddProps(['working',working, 'stats',stats.ComputeDetails,
          'threadstats',variant(pool)],result);
      finally
        stats.Free;
      end;
    except
      on E: Exception do
        result := ObjectToVariantDebug(E);
    end;
  finally
    fProcessLock.Leave;
  end;
end;

function TDDDMonitoredDaemon.RetrieveState(
  out Status: variant): TCQRSResult;
begin
  CqrsBeginMethod(qaNone,result,cqrsSuccess);
  Status := GetStatus;
end;

function TDDDMonitoredDaemon.Start: TCQRSResult;
var i: integer;
    {$ifdef WITHLOG}
    Log: ISynLog;
    {$endif}
    dummy: variant;
begin
  {$ifdef WITHLOG}
  Log := Rest.LogClass.Enter('Start %',[fProcessClass],self);
  {$endif}
  if fProcessClass=nil then
    raise EDDDException.CreateUTF8('%.Start with no fProcessClass',[self]);
  Stop(dummy); // ignore any error when stopping
  fProcessTimer.Resume;
  {$ifdef WITHLOG}
  if Log<>nil then
    Log.Log(sllTrace,'Start %',[self],self);
  {$endif}
  CqrsBeginMethod(qaNone,result,cqrsSuccess);
  SetLength(fProcess,fProcessThreadCount);
  for i := 0 to fProcessThreadCount-1 do
    fProcess[i] := fProcessClass.Create(self,i);
  SleepHiRes(1); // some time to actually start the threads
end;


function TDDDMonitoredDaemon.Stop(out Information: variant): TCQRSResult;
var i: integer;
    allfinished: boolean;
begin
  CqrsBeginMethod(qaNone,result);
  try
    if fProcess<>nil then begin
      fProcessTimer.Pause;
      Information := GetStatus;
      {$ifdef WITHLOG}
      Rest.LogClass.Enter('Stop % process %',[fProcessClass,Information],self);
      {$endif}
      fProcessLock.Enter;
      try
        for i := 0 to high(fProcess) do
          fProcess[i].Terminate;
      finally
        fProcessLock.Leave;
      end;
      repeat
        SleepHiRes(5);
        allfinished := true;
        fProcessLock.Enter;
        try
          for i := 0 to high(fProcess) do
            if fProcess[i].fMonitoring.Processing then begin
              allfinished := false;
              break;
            end;
        finally
          fProcessLock.Leave;
        end;
      until allfinished;
      fProcessLock.Enter;
      try
        ObjArrayClear(fProcess);
      finally
        fProcessLock.Leave;
      end;
    end;
    CqrsSetResult(cqrsSuccess,result);
  except
    on E: Exception do
      CqrsSetResult(E,result);
  end;
end;

initialization
  {$ifndef ISDELPHI2010}
  {$ifndef HASINTERFACERTTI} // circumvent a old FPC bug
  {TTextWriter.RegisterCustomJSONSerializerFromTextSimpleType([ TO-DO: mormot2conv
    TypeInfo(TCQRSResult), TypeInfo(TCQRSQueryAction), TypeInfo(TCQRSQueryState),
    TypeInfo(TDDDAdministratedDaemonStatus)]);}
  {$endif}
  {$endif}
  GetEnumNames(TypeInfo(TCQRSResult), @TCQRSResultText);
  TInterfaceFactory.RegisterInterfaces([
    TypeInfo(IMonitored),TypeInfo(IMonitoredDaemon){,
    TypeInfo(IAdministratedDaemon),TypeInfo(IAdministratedDaemonAsProxy)}]);

end.

