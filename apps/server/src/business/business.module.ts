import { Module } from '@nestjs/common';
import { PrismaModule } from '../prisma/prisma.module';
import { EventsService } from './events.service';
import { InventoryService } from './inventory.service';
import { MembershipsService } from './memberships.service';
import { NotesBusinessService } from './notes-business.service';
import { QuotesService } from './quotes.service';
import { TimeEntriesService } from './time-entries.service';
import { TodosService } from './todos.service';

/// 一处注册真实业务服务，后续协议入口直接注入，不增加七套控制器。
const businessServices = [
  QuotesService,
  TimeEntriesService,
  TodosService,
  InventoryService,
  MembershipsService,
  EventsService,
  NotesBusinessService,
];

/// 七模块可复用后端能力；不包含模型会话或 MCP 传输。
@Module({
  imports: [PrismaModule],
  providers: businessServices,
  exports: businessServices,
})
export class BusinessModule {}
