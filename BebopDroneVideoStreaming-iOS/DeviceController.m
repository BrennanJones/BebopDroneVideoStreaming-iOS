/*
    Copyright (C) 2014 Parrot SA

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in
      the documentation and/or other materials provided with the 
      distribution.
    * Neither the name of Parrot nor the names
      of its contributors may be used to endorse or promote products
      derived from this software without specific prior written
      permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
    OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED 
    AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
    OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
    OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
    SUCH DAMAGE.
*/
//
//  DeviceController.m
//  BebopDronePiloting
//
//  Created by  20/01/2015.
//  Copyright (c) 2015 Parrot. All rights reserved.
//

#import "DeviceController.h"

#import <libARSAL/ARSAL.h>
#import <libARStream/ARStream.h>
#import <libARNetwork/ARNetwork.h>
#import <libARNetworkAL/ARNetworkAL.h>
#import <libARCommands/ARCommands.h>

static const char* TAG = "DeviceController";

static const int BD_NET_C2D_NONACK = 10;
static const int BD_NET_C2D_ACK = 11;
static const int BD_NET_C2D_EMERGENCY = 12;
static const int BD_NET_C2D_VIDEO_ACK = 13;
static const int BD_NET_D2C_NAVDATA = 127;
static const int BD_NET_D2C_EVENTS = 126;
static const int BD_NET_D2C_VIDEO_DATA = 125;

static const int BD_NET_DC_VIDEO_FRAG_SIZE = 1000;
static const int BD_NET_DC_VIDEO_MAX_NUMBER_OF_FRAG = 128;

static const int D2C_PORT = 43210;  // fixed by the app, but should be sent to drone in json

static const int PCMD_LOOP_IN_MS = 25; // piloting command sending interval

static ARNETWORK_IOBufferParam_t C2D_PARAMS[] = {
    {
        .ID = BD_NET_C2D_NONACK,
        .dataType = ARNETWORKAL_FRAME_TYPE_DATA,
        .sendingWaitTimeMs = 20,
        .ackTimeoutMs = -1,
        .numberOfRetry = -1,
        .numberOfCell = 1,
        .dataCopyMaxSize = ARNETWORK_IOBUFFERPARAM_DATACOPYMAXSIZE_USE_MAX,
        .isOverwriting = 1,
    },
    {
        .ID = BD_NET_C2D_ACK,
        .dataType = ARNETWORKAL_FRAME_TYPE_DATA_WITH_ACK,
        .sendingWaitTimeMs = 20,
        .ackTimeoutMs = 500,
        .numberOfRetry = 3,
        .numberOfCell = 20,
        .dataCopyMaxSize = ARNETWORK_IOBUFFERPARAM_DATACOPYMAXSIZE_USE_MAX,
        .isOverwriting = 0,
    },
    {
        .ID = BD_NET_C2D_EMERGENCY,
        .dataType = ARNETWORKAL_FRAME_TYPE_DATA_WITH_ACK,
        .sendingWaitTimeMs = 1,
        .ackTimeoutMs = 100,
        .numberOfRetry = ARNETWORK_IOBUFFERPARAM_INFINITE_NUMBER,
        .numberOfCell = 1,
        .dataCopyMaxSize = ARNETWORK_IOBUFFERPARAM_DATACOPYMAXSIZE_USE_MAX,
        .isOverwriting = 0,
    },
    {
        .ID = BD_NET_C2D_VIDEO_ACK,
        .dataType = ARNETWORKAL_FRAME_TYPE_UNINITIALIZED,
        .sendingWaitTimeMs = 0,
        .ackTimeoutMs = 0,
        .numberOfRetry = 0,
        .numberOfCell = 0,
        .dataCopyMaxSize = 0,
        .isOverwriting = 0,
    }
};
static const size_t NUM_OF_C2D_PARAMS = sizeof(C2D_PARAMS) / sizeof(ARNETWORK_IOBufferParam_t);

static ARNETWORK_IOBufferParam_t D2C_PARAMS[] = {
    {
        .ID = BD_NET_D2C_NAVDATA,
        .dataType = ARNETWORKAL_FRAME_TYPE_DATA,
        .sendingWaitTimeMs = 20,
        .ackTimeoutMs = -1,
        .numberOfRetry = -1,
        .numberOfCell = 20,
        .dataCopyMaxSize = ARNETWORK_IOBUFFERPARAM_DATACOPYMAXSIZE_USE_MAX,
        .isOverwriting = 0,
    },
    {
        .ID = BD_NET_D2C_EVENTS,
        .dataType = ARNETWORKAL_FRAME_TYPE_DATA_WITH_ACK,
        .sendingWaitTimeMs = 20,
        .ackTimeoutMs = 500,
        .numberOfRetry = 3,
        .numberOfCell = 20,
        .dataCopyMaxSize = ARNETWORK_IOBUFFERPARAM_DATACOPYMAXSIZE_USE_MAX,
        .isOverwriting = 0,
    },
    {
        .ID = BD_NET_D2C_VIDEO_DATA,
        .dataType = ARNETWORKAL_FRAME_TYPE_UNINITIALIZED,
        .sendingWaitTimeMs = 0,
        .ackTimeoutMs = 0,
        .numberOfRetry = 0,
        .numberOfCell = 0,
        .dataCopyMaxSize = 0,
        .isOverwriting = 0,
    }
};
static const size_t NUM_OF_D2C_PARAMS = sizeof(D2C_PARAMS) / sizeof(ARNETWORK_IOBufferParam_t);

static int COMMAND_BUFFER_IDS[] = {
    BD_NET_D2C_NAVDATA,
    BD_NET_D2C_EVENTS,
};
static const size_t NUM_OF_COMMANDS_BUFFER_IDS = sizeof(COMMAND_BUFFER_IDS) / sizeof(int);

@interface DeviceController ()

@property (nonatomic, assign) ARNETWORKAL_Manager_t *alManager;
@property (nonatomic, assign) ARNETWORK_Manager_t *netManager;
@property (nonatomic) ARSAL_Thread_t rxThread;
@property (nonatomic) ARSAL_Thread_t txThread;
@property (nonatomic) int c2dPort;

@property (nonatomic) ARSAL_Thread_t looperThread;
@property (nonatomic) ARSAL_Thread_t *readerThreads;
@property (nonatomic) READER_THREAD_DATA_t *readerThreadsData;

@property (nonatomic) ARSTREAM_Reader_t *streamReader;
@property (nonatomic) uint8_t *videoFrame;
@property (nonatomic) uint32_t videoFrameSize;

@property (nonatomic) ARSAL_Thread_t videoRxThread;
@property (nonatomic) ARSAL_Thread_t videoTxThread;

@property (nonatomic) BOOL run;
@property (nonatomic) BOOL alManagerInitialized;

@property (nonatomic) BOOL initialSettingsReceived;
@property (nonatomic) NSCondition *initialSettingsReceivedCondition;
@property (nonatomic) BOOL initialStatesReceived;
@property (nonatomic) NSCondition *initialStatesReceivedCondition;

@property (nonatomic) BD_PCMD_t dataPCMD;

@property (nonatomic) dispatch_semaphore_t resolveSemaphore;

@end

@implementation DeviceController

- (id)initWithARService:(ARService*)service
{
    self = [super init];
    if (self)
    {
        _service = service;
        
        // initialize deviceManager
        _alManager = NULL;
        _netManager = NULL;
        _rxThread = NULL;
        _txThread = NULL;
        
        _videoRxThread = NULL;
        _videoTxThread = NULL;
        
        _looperThread = NULL;
        _readerThreads = NULL;
        _readerThreadsData = NULL;
        
        _initialSettingsReceived = NO;
        _initialSettingsReceivedCondition = [[NSCondition alloc] init];
        _initialStatesReceived = NO;
        _initialStatesReceivedCondition = [[NSCondition alloc] init];
        
        _run = YES;
        _alManagerInitialized = NO;
        
        _dataPCMD.flag = 0;
        _dataPCMD.roll = 0;
        _dataPCMD.pitch = 0;
        _dataPCMD.yaw = 0;
        _dataPCMD.gaz = 0;
        _dataPCMD.psi = 0;
    }
    
    return self;
}

- (void)dealloc
{

}

- (BOOL)start
{
    NSLog(@"start ...");
    
    BOOL failed = NO;
    
    // need to resolve service to get the IP
    BOOL resolveSucceeded = [self resolveService];
    if (!resolveSucceeded)
    {
        ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "resolveService failed.");
        failed = YES;
    }
    
    if (!failed)
    {
        failed = [self ardiscoveryConnect];
    }
    
    if (!failed)
    {
        ARSTREAM_Reader_InitStreamDataBuffer(&D2C_PARAMS[2], BD_NET_D2C_VIDEO_DATA, BD_NET_DC_VIDEO_FRAG_SIZE, BD_NET_DC_VIDEO_MAX_NUMBER_OF_FRAG);
        ARSTREAM_Reader_InitStreamAckBuffer(&C2D_PARAMS[3], BD_NET_C2D_VIDEO_ACK);
    }
    
    if (!failed)
    {
        failed = [self startNetwork];
    }
    
    if (!failed)
    {
        failed = [self sendBeginStream];
    }
    
    if (!failed)
    {
        // allocate reader thread array.
        _readerThreads = calloc(NUM_OF_COMMANDS_BUFFER_IDS, sizeof(ARSAL_Thread_t));
        
        if (_readerThreads == NULL)
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Allocation of reader threads failed.");
            failed = YES;
        }
    }
    
    if (!failed)
    {
        // allocate reader thread data array.
        _readerThreadsData = calloc(NUM_OF_COMMANDS_BUFFER_IDS, sizeof(READER_THREAD_DATA_t));
        
        if (_readerThreadsData == NULL)
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Allocation of reader threads data failed.");
            failed = YES;
        }
    }
    
    if (!failed)
    {
        // Create and start reader threads.
        int readerThreadIndex = 0;
        for (readerThreadIndex = 0 ; readerThreadIndex < NUM_OF_COMMANDS_BUFFER_IDS ; readerThreadIndex++)
        {
            // initialize reader thread data
            _readerThreadsData[readerThreadIndex].deviceController = (__bridge void *)self;
            _readerThreadsData[readerThreadIndex].readerBufferId = COMMAND_BUFFER_IDS[readerThreadIndex];
            
            if (ARSAL_Thread_Create(&(_readerThreads[readerThreadIndex]), readerRun, &(_readerThreadsData[readerThreadIndex])) != 0)
            {
                ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Creation of reader thread failed.");
                failed = YES;
            }
        }
    }
    
    if (!failed)
    {
        failed = [self startVideo];
    }
    
    if (!failed)
    {
        // Create and start looper thread.
        if (ARSAL_Thread_Create(&(_looperThread), looperRun, (__bridge void *)self) != 0)
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Creation of looper thread failed.");
            failed = YES;
        }
    }
    
    if (!failed)
    {
        [self registerARCommandsCallbacks];
    }
    
    NSDate *currentDate = [NSDate date];
    if (!failed)
    {
        failed = [self sendDate:currentDate];
    }
    
    if (!failed)
    {
        failed = [self sendTime:currentDate];
    }
    
    if (!failed)
    {
        failed = [self getInitialSettings];
    }
    
    if (!failed)
    {
        failed = [self getInitialStates];
    }
    
    return failed;
}

- (BOOL)ardiscoveryConnect
{
    int failed = 0;
    
    ARSAL_PRINT(ARSAL_PRINT_INFO, TAG, "- ARDiscovery Connection");
    
    eARDISCOVERY_ERROR err = ARDISCOVERY_OK;
    
    ARDISCOVERY_Connection_ConnectionData_t *discoveryData = ARDISCOVERY_Connection_New (ARDISCOVERY_Connection_SendJsonCallback, ARDISCOVERY_Connection_ReceiveJsonCallback, (__bridge void *)self, &err);
    if (discoveryData == NULL || err != ARDISCOVERY_OK)
    {
        ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Error while creating discoveryData : %s", ARDISCOVERY_Error_ToString(err));
        failed = 1;
    }
    
    if (!failed)
    {
        NSString *ip = [[ARDiscovery sharedInstance] convertNSNetServiceToIp:_service];
        int port = [(NSNetService *)_service.service port];
        if (ip)
        {
            eARDISCOVERY_ERROR err = ARDISCOVERY_Connection_ControllerConnection(discoveryData, port, [ip UTF8String]);
            if (err != ARDISCOVERY_OK)
            {
                ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Error while opening discovery connection : %s", ARDISCOVERY_Error_ToString(err));
                failed = 1;
            }
        }
        else
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "IP of service is null");
            failed = 1;
        }
    }
    
    ARDISCOVERY_Connection_Delete(&discoveryData);
    
    return failed;
}

eARDISCOVERY_ERROR ARDISCOVERY_Connection_SendJsonCallback (uint8_t *dataTx, uint32_t *dataTxSize, void *customData)
{
    eARDISCOVERY_ERROR err = ARDISCOVERY_OK;
    
    if ((dataTx != NULL) && (dataTxSize != NULL))
    {
        *dataTxSize = sprintf((char *)dataTx, "{ \"%s\": %d,\n \"%s\": \"%s\",\n \"%s\": \"%s\" }",
                              ARDISCOVERY_CONNECTION_JSON_D2CPORT_KEY, D2C_PORT,
                              ARDISCOVERY_CONNECTION_JSON_CONTROLLER_NAME_KEY, "bebopDroneSample",
                              ARDISCOVERY_CONNECTION_JSON_CONTROLLER_TYPE_KEY, "iOSController") + 1;
    }
    else
    {
        err = ARDISCOVERY_ERROR;
    }
    
    return err;
}

eARDISCOVERY_ERROR ARDISCOVERY_Connection_ReceiveJsonCallback (uint8_t *dataRx, uint32_t dataRxSize, char *ip, void *customData)
{
    DeviceController *deviceController = (__bridge DeviceController *)customData;
    eARDISCOVERY_ERROR err = ARDISCOVERY_OK;
    
    if ((dataRx != NULL) && (dataRxSize != 0))
    {
        char *json = malloc(dataRxSize + 1);
        strncpy(json, (char *)dataRx, dataRxSize);
        json[dataRxSize] = '\0';
        
        //read c2dPort ...
        NSString *strResponse = [NSString stringWithCString:(const char *)json encoding:NSUTF8StringEncoding];

        [deviceController readJson:strResponse];
        
        ARSAL_PRINT(ARSAL_PRINT_DEBUG, TAG, "    - ReceiveJson:%s ", json);
        
        free(json);
    }
    else
    {
        err = ARDISCOVERY_ERROR;
    }
    
    return err;
}

- (void)readJson:(NSString*)jsonStr
{
    NSError *err;
    id jsonobj = nil;
    
    if (jsonStr != nil)
    {
        jsonobj = [NSJSONSerialization JSONObjectWithData:[jsonStr dataUsingEncoding:NSUTF8StringEncoding] options:kNilOptions error:&err];
    }
    else
    {
        NSLog(@"error json = nil");
    }
    
    NSDictionary *jsonDict = (NSDictionary *)jsonobj;
    NSNumber *c2dPortData = [jsonDict objectForKey:[NSString stringWithCString:ARDISCOVERY_CONNECTION_JSON_C2DPORT_KEY encoding:NSUTF8StringEncoding]];
    _c2dPort = c2dPortData.intValue;
}

- (BOOL)startNetwork
{
    BOOL failed = NO;
    eARNETWORK_ERROR netError = ARNETWORK_OK;
    eARNETWORKAL_ERROR netAlError = ARNETWORKAL_OK;
    int pingDelay = 0; // 0 means default, -1 means no ping
    
    ARSAL_PRINT(ARSAL_PRINT_INFO, TAG, "- Start ARNetwork");
    
    // Create the ARNetworkALManager
    _alManager = ARNETWORKAL_Manager_New(&netAlError);
    if (netAlError != ARNETWORKAL_OK)
    {
        failed = YES;
    }
    
    if (!failed)
    {
        // Setup ARNetworkAL for Wifi.
        NSString *ip = [[ARDiscovery sharedInstance] convertNSNetServiceToIp:_service];
        if (ip)
        {
            netAlError = ARNETWORKAL_Manager_InitWifiNetwork(_alManager, [ip UTF8String], _c2dPort, D2C_PORT, 1);
            if (netAlError != ARNETWORKAL_OK)
            {
                ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "ARNETWORKAL_Manager_InitWifiNetwork() failed. %s", ARNETWORKAL_Error_ToString(netAlError));
                failed = YES;
            }
            else
            {
                _alManagerInitialized = YES;
            }
        }
        else
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "IP of service is null");
            failed = YES;
        }
    }
    
    if (!failed)
    {
        // Create the ARNetworkManager.
        _netManager = ARNETWORK_Manager_New(_alManager, NUM_OF_C2D_PARAMS, C2D_PARAMS, NUM_OF_D2C_PARAMS, D2C_PARAMS, pingDelay, onDisconnectNetwork, (__bridge void *)self, &netError);
        if (netError != ARNETWORK_OK)
        {
            failed = YES;
        }
    }
    
    if (!failed)
    {
        // Create and start Tx and Rx threads.
        if (ARSAL_Thread_Create(&(_rxThread), ARNETWORK_Manager_ReceivingThreadRun, _netManager) != 0)
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Creation of Rx thread failed.");
            failed = YES;
        }
        
        if (ARSAL_Thread_Create(&(_txThread), ARNETWORK_Manager_SendingThreadRun, _netManager) != 0)
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Creation of Tx thread failed.");
            failed = YES;
        }
    }
    
    // Print net error
    if (failed)
    {
        if (netAlError != ARNETWORKAL_OK)
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "ARNetWorkAL Error : %s", ARNETWORKAL_Error_ToString(netAlError));
        }
        
        if (netError != ARNETWORK_OK)
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "ARNetWork Error : %s", ARNETWORK_Error_ToString(netError));
        }
    }
    
    return failed;
}

- (BOOL) startVideo
{
    BOOL failed = NO;
    eARSTREAM_ERROR err = ARSTREAM_OK;
    
    ARSAL_PRINT(ARSAL_PRINT_INFO, TAG, "- Start ARStream");
    
    _videoFrameSize = BD_NET_DC_VIDEO_FRAG_SIZE * BD_NET_DC_VIDEO_MAX_NUMBER_OF_FRAG;
    _videoFrame = malloc(_videoFrameSize);
    
    if (_videoFrame == NULL)
    {
        failed = YES;
    }
    
    if (!failed)
    {
        _streamReader = ARSTREAM_Reader_New(_netManager, BD_NET_D2C_VIDEO_DATA, BD_NET_C2D_VIDEO_ACK, frameCompleteCallback, _videoFrame, _videoFrameSize, BD_NET_DC_VIDEO_FRAG_SIZE, ARSTREAM_READER_MAX_ACK_INTERVAL_DEFAULT, (__bridge void *)self, &err);
        
        if (err != ARSTREAM_OK)
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Error during ARStream creation : %s", ARSTREAM_Error_ToString(err));
            failed = YES;
        }
    }
    
    if (!failed)
    {
        if (ARSAL_Thread_Create(&(_videoRxThread), ARSTREAM_Reader_RunDataThread, _streamReader) != 0)
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Creation of video Rx thread failed.");
            failed = YES;
        }
        
        if (ARSAL_Thread_Create(&(_videoTxThread), ARSTREAM_Reader_RunAckThread, _streamReader) != 0)
        {
            ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Creation of video Tx thread failed.");
            failed = YES;
        }
    }
    
    return failed;
}

- (void)stop
{
    NSLog(@"stop ...");
    
    _run = 0; // break threads loops
    
    [self unregisterARCommandsCallbacks];
    
    // Stop looper Thread
    if (_looperThread != NULL)
    {
        ARSAL_Thread_Join(_looperThread, NULL);
        ARSAL_Thread_Destroy(&(_looperThread));
        _looperThread = NULL;
    }
    
    if (_readerThreads != NULL)
    {
        // Stop reader Threads
        int readerThreadIndex = 0;
        for (readerThreadIndex = 0 ; readerThreadIndex < NUM_OF_D2C_PARAMS ; readerThreadIndex++)
        {
            if (_readerThreads[readerThreadIndex] != NULL)
            {
                ARSAL_Thread_Join(_readerThreads[readerThreadIndex], NULL);
                ARSAL_Thread_Destroy(&(_readerThreads[readerThreadIndex]));
                _readerThreads[readerThreadIndex] = NULL;
            }
        }
        
        // free reader thread array
        free (_readerThreads);
        _readerThreads = NULL;
    }
    
    if (_readerThreadsData != NULL)
    {
        // free reader thread data array
        free (_readerThreadsData);
        _readerThreadsData = NULL;
    }
    
    // Stop video thread
    [self stopVideo];
    
    // Stop Network
    [self stopNetwork];
}

- (void)stopNetwork
{
    ARSAL_PRINT(ARSAL_PRINT_INFO, TAG, "- Stop ARNetwork");
    
    // ARNetwork cleanup
    if (_netManager != NULL)
    {
        ARNETWORK_Manager_Stop(_netManager);
        if (_rxThread != NULL)
        {
            ARSAL_Thread_Join(_rxThread, NULL);
            ARSAL_Thread_Destroy(&(_rxThread));
            _rxThread = NULL;
        }
        
        if (_txThread != NULL)
        {
            ARSAL_Thread_Join(_txThread, NULL);
            ARSAL_Thread_Destroy(&(_txThread));
            _txThread = NULL;
        }
    }
    
    if ((_alManager != NULL) && (_alManagerInitialized == YES))
    {
        ARNETWORKAL_Manager_Unlock(_alManager);
        
        ARNETWORKAL_Manager_CloseWifiNetwork(_alManager);
    }
    
    ARNETWORK_Manager_Delete(&(_netManager));
    ARNETWORKAL_Manager_Delete(&(_alManager));
}

- (void) stopVideo
{
    ARSAL_PRINT(ARSAL_PRINT_INFO, TAG, "- Stop ARStream");
    
    if (_streamReader)
    {
        ARSTREAM_Reader_StopReader(_streamReader);
        
        ARNETWORKAL_Manager_Unlock(_alManager);
        
        if (_videoRxThread != NULL)
        {
            ARSAL_Thread_Join(_videoRxThread, NULL);
            ARSAL_Thread_Destroy(&(_videoRxThread));
            _videoRxThread = NULL;
        }
        if (_videoTxThread != NULL)
        {
            ARSAL_Thread_Join(_videoTxThread, NULL);
            ARSAL_Thread_Destroy(&(_videoTxThread));
            _videoTxThread = NULL;
        }
        
        ARSTREAM_Reader_Delete (&(_streamReader));
    }
    
    if (_videoFrame)
    {
        free (_videoFrame);
        _videoFrame = NULL;
    }
}

/**
 * @brief fuction called on disconnect
 * @param manager The manager
 */
void onDisconnectNetwork (ARNETWORK_Manager_t *manager, ARNETWORKAL_Manager_t *alManager, void *customData)
{
    DeviceController *deviceController = (__bridge DeviceController*)customData;
    
    NSLog(@"onDisconnectNetwork ... %@ : %@", deviceController, [deviceController delegate]);
    
    if ((deviceController != nil) && (deviceController.delegate != nil))
    {
        [deviceController.delegate onDisconnectNetwork:deviceController];
    }
}

void *looperRun (void* data)
{
    DeviceController *deviceController = (__bridge DeviceController*)data;
    
    if(deviceController != NULL)
    {
        while (deviceController.run)
        {
            [deviceController sendPCMD];
            
            usleep(PCMD_LOOP_IN_MS * 1000);
        }
    }
    
    return NULL;
}

void *readerRun (void* data)
{
    DeviceController *deviceController = NULL;
    int bufferId = 0;
    int failed = 0;
    
    // Allocate some space for incoming data.
    const size_t maxLength = 128 * 1024;
    void *readData = malloc (maxLength);
    if (readData == NULL)
    {
        failed = 1;
    }
    
    if (!failed)
    {
        // get thread data.
        if (data != NULL)
        {
            bufferId = ((READER_THREAD_DATA_t *)data)->readerBufferId;
            deviceController = (__bridge DeviceController*)((READER_THREAD_DATA_t *)data)->deviceController;
            
            if (deviceController == NULL)
            {
                failed = 1;
            }
        }
        else
        {
            failed = 1;
        }
    }
    
    if (!failed)
    {
        while (deviceController.run)
        {
            eARNETWORK_ERROR netError = ARNETWORK_OK;
            int length = 0;
            int skip = 0;
            
            // read data
            netError = ARNETWORK_Manager_ReadDataWithTimeout (deviceController.netManager, bufferId, readData, maxLength, &length, 1000);
            if (netError != ARNETWORK_OK)
            {
                if (netError != ARNETWORK_ERROR_BUFFER_EMPTY)
                {
                    ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "ARNETWORK_Manager_ReadDataWithTimeout () failed : %s", ARNETWORK_Error_ToString(netError));
                }
                skip = 1;
            }
            
            if (!skip)
            {
                // Forward data to the CommandsManager
                eARCOMMANDS_DECODER_ERROR cmdError = ARCOMMANDS_DECODER_OK;
                cmdError = ARCOMMANDS_Decoder_DecodeBuffer ((uint8_t *)readData, length);
                if ((cmdError != ARCOMMANDS_DECODER_OK) && (cmdError != ARCOMMANDS_DECODER_ERROR_NO_CALLBACK))
                {
                    char msg[128];
                    ARCOMMANDS_Decoder_DescribeBuffer ((uint8_t *)readData, length, msg, sizeof(msg));
                    ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "ARCOMMANDS_Decoder_DecodeBuffer () failed : %d %s", cmdError, msg);
                }
            }
        }
    }
    
    if (readData != NULL)
    {
        free (readData);
        readData = NULL;
    }
    
    return NULL;
}

eARNETWORK_MANAGER_CALLBACK_RETURN arnetworkCmdCallback(int buffer_id, uint8_t *data, void *custom, eARNETWORK_MANAGER_CALLBACK_STATUS cause)
{
    eARNETWORK_MANAGER_CALLBACK_RETURN retval = ARNETWORK_MANAGER_CALLBACK_RETURN_DEFAULT;
    
    if (cause == ARNETWORK_MANAGER_CALLBACK_STATUS_TIMEOUT)
    {
        retval = ARNETWORK_MANAGER_CALLBACK_RETURN_DATA_POP;
    }
    
    return retval;
}

uint8_t *frameCompleteCallback (eARSTREAM_READER_CAUSE cause, uint8_t *frame, uint32_t frameSize, int numberOfSkippedFrames, int isFlushFrame, uint32_t *newBufferCapacity, void *custom)
{
    uint8_t *ret = NULL;
    DeviceController *deviceController = (__bridge DeviceController*)custom;
    
    switch(cause)
    {
        case ARSTREAM_READER_CAUSE_FRAME_COMPLETE:
            [deviceController.delegate onFrameComplete:deviceController frame:frame frameSize:frameSize];
            ret = deviceController->_videoFrame;
            
            break;
        case ARSTREAM_READER_CAUSE_FRAME_TOO_SMALL:
            /* This case should not happen, as we've allocated a frame pointer to the maximum possible size. */
            break;
        case ARSTREAM_READER_CAUSE_COPY_COMPLETE:
            /* Same as before ... but return value are ignored, so we just do nothing */
            break;
        case ARSTREAM_READER_CAUSE_CANCEL:
            /* Called when the library closes, return values ignored, so do nothing here */
            break;
        default:
            break;
    }
    
    return ret;
}

#pragma mark sending functions
- (BOOL)getInitialSettings
{
    BOOL failed = NO;
    
    [_initialSettingsReceivedCondition lock];
    u_int8_t cmdBuffer[128];
    int32_t cmdSize = 0;
    eARCOMMANDS_GENERATOR_ERROR cmdError;
    eARNETWORK_ERROR netError = ARNETWORK_ERROR;
    
    ARSAL_PRINT(ARSAL_PRINT_INFO, TAG, "- Send get all settings");
    
    // Send get all settings
    cmdError = ARCOMMANDS_Generator_GenerateCommonSettingsAllSettings(cmdBuffer, sizeof(cmdBuffer), &cmdSize);
    if (cmdError == ARCOMMANDS_GENERATOR_OK)
    {
        netError = ARNETWORK_Manager_SendData(_netManager, BD_NET_C2D_ACK, cmdBuffer, cmdSize, NULL, &(arnetworkCmdCallback), 1);
    }
    
    if ((cmdError != ARCOMMANDS_GENERATOR_OK) || (netError != ARNETWORK_OK))
    {
        ARSAL_PRINT(ARSAL_PRINT_WARNING, TAG, "Failed to send get all settings command. cmdError:%d netError:%s", cmdError, ARNETWORK_Error_ToString(netError));
        failed = YES;
    }
    
    if(!failed)
    {
        // wait for all settings to be received
        [_initialSettingsReceivedCondition wait];
    }
    
    if (!_initialSettingsReceived)
    {
        ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Initial settings retrieval timed out.");
        failed = YES;
    }
    [_initialSettingsReceivedCondition unlock];
    
    return failed;
}

- (BOOL) getInitialStates
{
    BOOL failed = NO;
    
    [_initialStatesReceivedCondition lock];
    u_int8_t cmdBuffer[128];
    int32_t cmdSize = 0;
    eARCOMMANDS_GENERATOR_ERROR cmdError;
    eARNETWORK_ERROR netError = ARNETWORK_ERROR;
    
    ARSAL_PRINT(ARSAL_PRINT_INFO, TAG, "- Send get all states");
    
    // Send get all states
    cmdError = ARCOMMANDS_Generator_GenerateCommonCommonAllStates(cmdBuffer, sizeof(cmdBuffer), &cmdSize);
    if (cmdError == ARCOMMANDS_GENERATOR_OK)
    {
        netError = ARNETWORK_Manager_SendData(_netManager, BD_NET_C2D_ACK, cmdBuffer, cmdSize, NULL, &(arnetworkCmdCallback), 1);
    }
    
    if ((cmdError != ARCOMMANDS_GENERATOR_OK) || (netError != ARNETWORK_OK))
    {
        ARSAL_PRINT(ARSAL_PRINT_WARNING, TAG, "Failed to send get all states command. cmdError:%d netError:%s", cmdError, ARNETWORK_Error_ToString(netError));
        failed = YES;
    }
    
    if(!failed)
    {
        // wait for all states to be received
        [_initialStatesReceivedCondition wait];
    }
    
    if (!_initialStatesReceived)
    {
        ARSAL_PRINT(ARSAL_PRINT_ERROR, TAG, "Initial states retrieval timed out.");
        failed = YES;
    }
    [_initialStatesReceivedCondition unlock];
    
    return failed;
}

- (BOOL) sendPCMD
{
    BOOL sentStatus = YES;
    u_int8_t cmdBuffer[128];
    int32_t cmdSize = 0;
    eARCOMMANDS_GENERATOR_ERROR cmdError;
    eARNETWORK_ERROR netError = ARNETWORK_ERROR;
    
    // Send Posture command
    cmdError = ARCOMMANDS_Generator_GenerateARDrone3PilotingPCMD(cmdBuffer, sizeof(cmdBuffer), &cmdSize, _dataPCMD.flag, _dataPCMD.roll, _dataPCMD.pitch, _dataPCMD.yaw, _dataPCMD.gaz, _dataPCMD.psi);
    if (cmdError == ARCOMMANDS_GENERATOR_OK)
    {
        // The commands sent in loop should be sent to a buffer not acknowledged ; here JS_NET_CD_NONACK_ID
        netError = ARNETWORK_Manager_SendData(_netManager, BD_NET_C2D_NONACK, cmdBuffer, cmdSize, NULL, &(arnetworkCmdCallback), 1);
    }
    
    if ((cmdError != ARCOMMANDS_GENERATOR_OK) || (netError != ARNETWORK_OK))
    {
        sentStatus = NO;
    }
    
    return sentStatus;
}

- (BOOL) sendDate:(NSDate *)currentDate
{
    BOOL failed = NO;
    u_int8_t cmdBuffer[128];
    int32_t cmdSize = 0;
    eARCOMMANDS_GENERATOR_ERROR cmdError;
    eARNETWORK_ERROR netError = ARNETWORK_ERROR;
    
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setTimeZone:[NSTimeZone systemTimeZone]];
    [dateFormatter setLocale:[NSLocale systemLocale]];
    [dateFormatter setDateFormat:@"yyyy-MM-dd"];
    
    // Send date command
    cmdError = ARCOMMANDS_Generator_GenerateCommonCommonCurrentDate(cmdBuffer, sizeof(cmdBuffer), &cmdSize, (char *)[[dateFormatter stringFromDate:currentDate] cStringUsingEncoding:NSUTF8StringEncoding]);
    if (cmdError == ARCOMMANDS_GENERATOR_OK)
    {
        // The commands sent by event should be sent to an buffer acknowledged  ; here RS_NET_C2D_ACK
        netError = ARNETWORK_Manager_SendData(_netManager, BD_NET_C2D_ACK, cmdBuffer, cmdSize, NULL, &(arnetworkCmdCallback), 1);
    }
    
    if ((cmdError != ARCOMMANDS_GENERATOR_OK) || (netError != ARNETWORK_OK))
    {
        failed = YES;
    }
    
    return failed;
}

- (BOOL) sendTime:(NSDate *)currentDate
{
    BOOL failed = NO;
    u_int8_t cmdBuffer[128];
    int32_t cmdSize = 0;
    eARCOMMANDS_GENERATOR_ERROR cmdError;
    eARNETWORK_ERROR netError = ARNETWORK_ERROR;
    
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setTimeZone:[NSTimeZone systemTimeZone]];
    [dateFormatter setLocale:[NSLocale systemLocale]];
    [dateFormatter setDateFormat:@"'T'HHmmssZZZ"];
    
    // Send time command
    cmdError = ARCOMMANDS_Generator_GenerateCommonCommonCurrentTime(cmdBuffer, sizeof(cmdBuffer), &cmdSize, (char *)[[dateFormatter stringFromDate:currentDate] cStringUsingEncoding:NSUTF8StringEncoding]);
    if (cmdError == ARCOMMANDS_GENERATOR_OK)
    {
        // The commands sent by event should be sent to an buffer acknowledged  ; here RS_NET_C2D_ACK
        netError = ARNETWORK_Manager_SendData(_netManager, BD_NET_C2D_ACK, cmdBuffer, cmdSize, NULL, &(arnetworkCmdCallback), 1);
    }
    
    if ((cmdError != ARCOMMANDS_GENERATOR_OK) || (netError != ARNETWORK_OK))
    {
        failed = YES;
    }
    
    return failed;
}

- (BOOL) sendBeginStream
{
    BOOL failed = NO;
    u_int8_t cmdBuffer[128];
    int32_t cmdSize = 0;
    eARCOMMANDS_GENERATOR_ERROR cmdError;
    eARNETWORK_ERROR netError = ARNETWORK_ERROR;
    
    ARSAL_PRINT(ARSAL_PRINT_INFO, TAG, "- Send Streaming Begin");
    
    // Send Streaming begin command
    cmdError = ARCOMMANDS_Generator_GenerateARDrone3MediaStreamingVideoEnable(cmdBuffer, sizeof(cmdBuffer), &cmdSize, 1);
    if (cmdError == ARCOMMANDS_GENERATOR_OK)
    {
        netError = ARNETWORK_Manager_SendData(_netManager, BD_NET_C2D_ACK, cmdBuffer, cmdSize, NULL, &(arnetworkCmdCallback), 1);
    }
    
    if ((cmdError != ARCOMMANDS_GENERATOR_OK) || (netError != ARNETWORK_OK))
    {
        ARSAL_PRINT(ARSAL_PRINT_WARNING, TAG, "Failed to send Streaming command. cmdError:%d netError:%s", cmdError, ARNETWORK_Error_ToString(netError));
        failed = YES;
    }
    
    return failed;
}

#pragma mark commands callbacks
-(void) registerARCommandsCallbacks
{
    ARCOMMANDS_Decoder_SetCommonCommonStateAllStatesChangedCallback(allStatesCallback, (__bridge void *)self);
    ARCOMMANDS_Decoder_SetCommonSettingsStateAllSettingsChangedCallback(allSettingsCallback, (__bridge void *)self);
}

-(void) unregisterARCommandsCallbacks
{
    ARCOMMANDS_Decoder_SetCommonCommonStateAllStatesChangedCallback(NULL, NULL);
    ARCOMMANDS_Decoder_SetCommonSettingsStateAllSettingsChangedCallback(NULL, NULL);
}

void allStatesCallback (void *custom)
{
    // all states received, that means that the drone has now sent all states
    // if you were listening for settings (like ARCOMMANDS_Decoder_CommonCommonStateBatteryStateChangedCallback_t), you should have receive it
    NSLog(@"All states received ... ");
    DeviceController *deviceController = (__bridge DeviceController*)custom;
    
    [deviceController.initialStatesReceivedCondition lock];
    deviceController.initialStatesReceived = YES;
    [deviceController.initialStatesReceivedCondition signal];
    [deviceController.initialStatesReceivedCondition unlock];
}

void allSettingsCallback (void *custom)
{
    // all settings received, that means that the drone has now sent all settings
    // if you were listening for settings (like ARCOMMANDS_Decoder_ARDrone3PilotingSettingsMaxAltitudeCallback_t), you should have receive it
    NSLog(@"All settings received ... ");
    
    DeviceController *deviceController = (__bridge DeviceController*)custom;
    
    [deviceController.initialSettingsReceivedCondition lock];
    deviceController.initialSettingsReceived = YES;
    [deviceController.initialSettingsReceivedCondition signal];
    [deviceController.initialSettingsReceivedCondition unlock];
}

#pragma mark resolveService
- (BOOL)resolveService
{
    BOOL retval = NO;
    _resolveSemaphore = dispatch_semaphore_create(0);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(discoveryDidResolve:) name:kARDiscoveryNotificationServiceResolved object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(discoveryDidNotResolve:) name:kARDiscoveryNotificationServiceNotResolved object:nil];
    
    [[ARDiscovery sharedInstance] resolveService:_service];
    
    // this semaphore will be signaled in discoveryDidResolve and discoveryDidNotResolve
    dispatch_semaphore_wait(_resolveSemaphore, dispatch_time(DISPATCH_TIME_NOW, 10000000000));
    
    if (_service)
    {
        NSString *ip = [[ARDiscovery sharedInstance] convertNSNetServiceToIp:_service];
        if (ip != nil)
        {
            retval = YES;
        }
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kARDiscoveryNotificationServiceResolved object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kARDiscoveryNotificationServiceNotResolved object:nil];
    _resolveSemaphore = nil;
    return retval;
}

- (void)discoveryDidResolve:(NSNotification *)notification
{
    _service = (ARService *)[[notification userInfo] objectForKey:kARDiscoveryServiceResolved];
    dispatch_semaphore_signal(_resolveSemaphore);
}

- (void)discoveryDidNotResolve:(NSNotification *)notification
{
    _service = nil;
    dispatch_semaphore_signal(_resolveSemaphore);
}

@end
